package com.dase.bigdata.job;

import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.storm.Config;
import org.apache.storm.StormSubmitter;
import org.apache.storm.kafka.spout.KafkaSpout;
import org.apache.storm.kafka.spout.KafkaSpoutConfig;
import org.apache.storm.spout.SpoutOutputCollector;
import org.apache.storm.task.OutputCollector;
import org.apache.storm.task.TopologyContext;
import org.apache.storm.topology.IRichSpout;
import org.apache.storm.topology.OutputFieldsDeclarer;
import org.apache.storm.topology.TopologyBuilder;
import org.apache.storm.topology.base.BaseRichBolt;
import org.apache.storm.topology.base.BaseRichSpout;
import org.apache.storm.tuple.Fields;
import org.apache.storm.tuple.Tuple;
import org.apache.storm.tuple.Values;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;

import java.time.Duration;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Storm At-Least-Once 异常注入测试拓扑
 * 
 * 核心配置（隔离部署）：
 * - Spout → Worker 1 (并发=4)
 * - Process Bolt → Worker 2 (并发=4)
 * - Sink Bolt → Worker 3 (并发=4)
 * - Acker → Worker 4 (并发=1)
 * - spout.max.pending: 可配置（用于测试重复率）
 * 
 * 异常注入配置（通过 JVM 参数控制）：
 * - fault.spout.enabled: 是否在 Spout 中注入异常
 * - fault.bolt.enabled: 是否在 Bolt 中注入异常
 * - fault.bolt.before.emit: Bolt 异常在 emit 之前（true）还是之后（false）
 * - fault.lambda: 泊松分布参数，平均每处理多少条消息发生一次故障（默认 10000）
 *                例如：lambda=5000 表示平均每5000条消息发生一次故障
 *                故障间隔服从指数分布，更符合真实故障场景
 * 
 * 部署位置：Node 1 提交
 */
public class StormAtLeastOnceTopologyWithFaultInjection {
    private static final Logger LOG = LoggerFactory.getLogger(StormAtLeastOnceTopologyWithFaultInjection.class);

    public static void main(String[] args) throws Exception {
        // 1. [实验核心] 构建拓扑
        TopologyBuilder builder = new TopologyBuilder();

        // [始终使用自定义 Spout，在 Worker 中读取参数决定是否注入故障]
        builder.setSpout("kafka-spout", new KafkaSpoutWithFaultInjection(), 4);

        // [资源分配] Process Bolt 并发=4
        builder.setBolt("process-bolt", new ProcessBoltWithFaultInjection(), 4)
               .shuffleGrouping("kafka-spout");
        
        // [资源分配] Sink Bolt 并发=4（独立 Worker 3）
        builder.setBolt("sink-bolt", new KafkaSinkBolt(), 4)
               .shuffleGrouping("process-bolt");

        // 3. 拓扑配置
        Config conf = new Config();
        
        // [实验核心] 开启 Acker (1个，独立 Worker 4)
        conf.setNumAckers(1);
        
        // [实验核心] 总 Worker 数 = 4 (Spout + Process + Sink + Acker 隔离)
        conf.setNumWorkers(4);
        
        // [实验关键] spout.max.pending 配置（用于测试重复率）
        int maxPending = Integer.parseInt(System.getProperty("spout.max.pending", "1000"));
        conf.put(Config.TOPOLOGY_MAX_SPOUT_PENDING, maxPending);
        
        // 超时设置 60s
        conf.setMessageTimeoutSecs(60);

        LOG.info("====================================" );
        LOG.info("Storm At-Least-Once Topology (Fault Injection) Submitting...");
        LOG.info("Num Ackers: 1");
        LOG.info("Num Workers: 4 (Isolated Deployment)");
        LOG.info("Spout Parallelism: 4");
        LOG.info("Process Bolt Parallelism: 4");
        LOG.info("Sink Bolt Parallelism: 4");
        LOG.info("Spout Max Pending: {}", maxPending);
        LOG.info("Source Topic: source_data");
        LOG.info("Sink Topic: storm_sink");
        LOG.info("");
        LOG.info("Worker JVM 参数配置（将传递给 Worker 进程）:");
        Object workerOpts = conf.get(Config.TOPOLOGY_WORKER_CHILDOPTS);
        if (workerOpts != null) {
            LOG.info("  {}", workerOpts);
        } else {
            LOG.info("  (无自定义参数)");
        }
        LOG.info("");
        LOG.info("注意: 故障注入在 Worker 启动时生效，请查看 Worker 日志确认");
        LOG.info("====================================");

        // 4. 提交拓扑
        String topologyName = args.length > 0 ? args[0] : "Storm-FaultInjection-Test";
        StormSubmitter.submitTopology(topologyName, conf, builder.createTopology());
    }

    /**
     * 自定义 Kafka Spout - 支持异常注入（基于泊松分布）
     */
    public static class KafkaSpoutWithFaultInjection extends BaseRichSpout {
        private static final Logger LOG = LoggerFactory.getLogger(KafkaSpoutWithFaultInjection.class);
        
        private SpoutOutputCollector collector;
        private KafkaConsumer<String, String> consumer;
        private long emittedCount = 0;
        private Random random = new Random();
        
        // 异常注入配置
        private double lambda = 10000.0;
        private long nextFaultAt = -1;
        
        // 消息追踪（用于 ACK/FAIL）
        private Map<Object, ConsumerRecord<String, String>> pendingMessages = new ConcurrentHashMap<>();
        private long messageIdCounter = 0;

        @Override
        public void open(Map<String, Object> conf, TopologyContext context, SpoutOutputCollector collector) {
            this.collector = collector;
            
            // [关键] 在 Worker 中读取 JVM 参数
            boolean faultEnabled = Boolean.parseBoolean(System.getProperty("fault.spout.enabled", "false"));
            this.lambda = Double.parseDouble(System.getProperty("fault.lambda", "10000"));
            
            if (!faultEnabled) {
                // 禁用故障注入，设置为无限大
                this.nextFaultAt = Long.MAX_VALUE;
                LOG.info("KafkaSpout initialized WITHOUT fault injection");
                LOG.info("  - Using official Kafka consumer behavior");
            } else {
                // 启用故障注入
                this.nextFaultAt = generateNextFaultInterval();
                LOG.info("KafkaSpout initialized WITH fault injection:");
                LOG.info("  - Lambda: {}", lambda);
                LOG.info("  - First fault at: {}", nextFaultAt);
            }
            
            // 初始化 Kafka Consumer
            Properties props = new Properties();
            props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "node1:9092,node2:9092,node3:9092");
            props.put(ConsumerConfig.GROUP_ID_CONFIG, "storm-fault-test-group");
            props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.StringDeserializer");
            props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.StringDeserializer");
            props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
            props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");  // 手动提交
            
            this.consumer = new KafkaConsumer<>(props);
            this.consumer.subscribe(Collections.singletonList("source_data"));
        }

        @Override
        public void nextTuple() {
            try {
                // 从 Kafka 拉取消息
                ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
                
                for (ConsumerRecord<String, String> record : records) {
                    // [异常注入] emit 之前抓异常
                    if (shouldInjectFault()) {
                        LOG.warn("⚠ Injecting fault in Spout at message #{}", emittedCount);
                        throw new RuntimeException("Injected fault in Spout");
                    }
                    
                    // 生成唯一 MessageId
                    Long messageId = messageIdCounter++;
                    pendingMessages.put(messageId, record);
                    
                    // 发射消息
                    collector.emit(new Values(record.key(), record.value()), messageId);
                    emittedCount++;
                    
                    if (emittedCount % 10000 == 0) {
                        LOG.info("Emitted {} messages from Spout", emittedCount);
                    }
                }
                
            } catch (Exception e) {
                LOG.error("Error in Spout nextTuple: {}", e.getMessage());
                // Spout 异常时休眠一下，防止狂转
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                }
            }
        }

        @Override
        public void ack(Object msgId) {
            // ACK 成功，提交 offset
            ConsumerRecord<String, String> record = pendingMessages.remove(msgId);
            if (record != null) {
                consumer.commitSync();
            }
            
            // 更新下一个故障点
            if (emittedCount >= nextFaultAt) {
                nextFaultAt = emittedCount + generateNextFaultInterval();
                LOG.info("✓ Message ACKed, next fault at #{}", nextFaultAt);
            }
        }

        @Override
        public void fail(Object msgId) {
            // FAIL 时，消息会被 Storm 自动重发
            LOG.warn("Message FAILED in Spout, will be replayed: {}", msgId);
            pendingMessages.remove(msgId);
        }

        @Override
        public void declareOutputFields(OutputFieldsDeclarer declarer) {
            declarer.declare(new Fields("key", "value"));
        }
        
        private boolean shouldInjectFault() {
            return emittedCount >= nextFaultAt;
        }
        
        private long generateNextFaultInterval() {
            double u = random.nextDouble();
            long interval = (long) (-lambda * Math.log(u));
            return Math.max(1, interval);
        }
        
        @Override
        public void close() {
            if (consumer != null) {
                consumer.close();
            }
        }
    }

    /**
     * 处理 Bolt - 支持异常注入（基于泊松分布）
     */
    public static class ProcessBoltWithFaultInjection extends BaseRichBolt {
        private static final Logger LOG = LoggerFactory.getLogger(ProcessBoltWithFaultInjection.class);
        private OutputCollector collector;
        private long processedCount = 0;
        private Random random = new Random();
        
        // 异常注入配置
        private boolean faultEnabled = false;
        private boolean faultBeforeEmit = false;
        private double lambda = 10000.0;      // 泊松分布参数
        private long nextFaultAt = -1;         // 下一次故障发生的消息序号
        private long faultInjectedMsgId = -1;  // 已注入故障的消息 ID（避免重复触发）

        @Override
        public void prepare(Map<String, Object> topoConf, TopologyContext context, OutputCollector collector) {
            this.collector = collector;
            
            // 读取异常注入配置
            this.faultEnabled = Boolean.parseBoolean(System.getProperty("fault.bolt.enabled", "false"));
            this.faultBeforeEmit = Boolean.parseBoolean(System.getProperty("fault.bolt.before.emit", "false"));
            this.lambda = Double.parseDouble(System.getProperty("fault.lambda", "10000"));
            
            if (this.faultEnabled) {
                // 初始化第一个故障点（基于泊松分布）
                this.nextFaultAt = generateNextFaultInterval();
            }
            
            LOG.info("ProcessBolt initialized with fault injection config:");
            LOG.info("  - Fault Enabled: {}", faultEnabled);
            LOG.info("  - Fault Before Emit: {}", faultBeforeEmit);
            LOG.info("  - Lambda (Avg Interval): {}", lambda);
            if (this.faultEnabled) {
                LOG.info("  - First fault scheduled at message #{}", this.nextFaultAt);
            }
        }

        @Override
        public void execute(Tuple input) {
            try {
                String value = input.getStringByField("value");
                JSONObject json = JSONObject.parseObject(value);
                long msgId = json.getLong("msg_id");
                
                // [异常注入点 1] emit 之前抛异常
                if (faultEnabled && faultBeforeEmit && shouldInjectFault(msgId)) {
                    LOG.warn("Injecting fault BEFORE emit for msg_id: {}", msgId);
                    faultInjectedMsgId = msgId;  // 记录故障消息
                    throw new RuntimeException("Injected fault before emit");
                }
                
                // [负载模拟] 强制休眠 1ms
                Thread.sleep(1);
                
                // 打上处理时间
                json.put("process_time", System.currentTimeMillis());
                json.put("processor", "storm");
                
                processedCount++;
                
                // 定期打印处理进度
                if (processedCount % 10000 == 0) {
                    LOG.info("Processed {} messages", processedCount);
                }
                
                // 发射到下游
                collector.emit(input, new Values(json.toJSONString()));
                
                // [异常注入点 2] emit 之后抛异常
                if (faultEnabled && !faultBeforeEmit && shouldInjectFault(msgId)) {
                    LOG.warn("Injecting fault AFTER emit for msg_id: {}", msgId);
                    faultInjectedMsgId = msgId;  // 记录故障消息
                    throw new RuntimeException("Injected fault after emit");
                }
                
                // [实验关键] 手动 ACK (确保可靠性)
                collector.ack(input);
                
                // ACK 成功后，更新下一个故障点
                if (faultEnabled && processedCount >= nextFaultAt) {
                    nextFaultAt = processedCount + generateNextFaultInterval();
                    LOG.info("✓ Message #{} processed successfully, next fault scheduled at #{}", 
                             processedCount, nextFaultAt);
                }
                
            } catch (Exception e) {
                LOG.error("Error processing tuple: {}", e.getMessage());
                // [实验关键] 处理失败时 FAIL (触发重试)
                collector.fail(input);
            }
        }
        
        /**
         * 判断当前消息是否应该注入故障（基于泊松分布）
         * 修复：通过 msg_id 避免同一消息重复触发故障
         */
        private boolean shouldInjectFault(long msgId) {
            if (!faultEnabled) {
                return false;
            }

            // 如果是重试的消息（msg_id 相同），不再触发故障
            if (msgId == faultInjectedMsgId) {
                LOG.debug("Skipping fault for retry msg_id: {}", msgId);
                return false;
            }

            // 检查是否到达故障点
            if (processedCount >= nextFaultAt) {
                LOG.info("⚠ Fault triggered at message #{} (msg_id: {})", processedCount, msgId);
                return true;
            }
            return false;
        }

        /**
         * 基于泊松分布生成下一次故障的时间间隔
         * 使用逆变换采样法：X = -λ * ln(U)，其中 U ~ Uniform(0,1)
         */
        private long generateNextFaultInterval() {
            // 生成 (0, 1) 区间的均匀随机数
            double u = random.nextDouble();
            // 泊松过程的事件间隔服从指数分布
            long interval = (long) (-lambda * Math.log(u));
            // 至少间隔 1 条消息
            return Math.max(1, interval);
        }

        @Override
        public void declareOutputFields(OutputFieldsDeclarer declarer) {
            declarer.declare(new Fields("message"));
        }
    }

    /**
     * Kafka Sink Bolt - 将结果写入 Kafka
     */
    public static class KafkaSinkBolt extends BaseRichBolt {
        private static final Logger LOG = LoggerFactory.getLogger(KafkaSinkBolt.class);
        private OutputCollector collector;
        private KafkaProducer<String, String> producer;
        private long sentCount = 0;

        @Override
        public void prepare(Map<String, Object> topoConf, TopologyContext context, OutputCollector collector) {
            this.collector = collector;
            
            // 初始化 Kafka Producer
            Properties props = new Properties();
            props.put("bootstrap.servers", "node1:9092,node2:9092,node3:9092");
            props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
            props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
            props.put("acks", "1");
            props.put("batch.size", 16384);
            props.put("linger.ms", 10);
            
            this.producer = new KafkaProducer<>(props);
            
            LOG.info("KafkaSinkBolt initialized");
        }

        @Override
        public void execute(Tuple input) {
            try {
                String message = input.getStringByField("message");
                
                // 发送到 Kafka
                producer.send(new ProducerRecord<>("storm_sink", null, message), (metadata, exception) -> {
                    if (exception != null) {
                        LOG.error("Failed to send message to Kafka", exception);
                    }
                });
                
                sentCount++;
                
                // 定期打印发送进度
                if (sentCount % 10000 == 0) {
                    LOG.info("Sent {} messages to Kafka", sentCount);
                }
                
                // [实验关键] ACK
                collector.ack(input);
                
            } catch (Exception e) {
                LOG.error("Error sending to Kafka", e);
                collector.fail(input);
            }
        }

        @Override
        public void declareOutputFields(OutputFieldsDeclarer declarer) {
            // 终端 Bolt，无需声明输出
        }

        @Override
        public void cleanup() {
            if (producer != null) {
                producer.close();
            }
        }
    }
}
