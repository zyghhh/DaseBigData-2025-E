package com.dase.bigdata.job;

import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.storm.Config;
import org.apache.storm.StormSubmitter;
import org.apache.storm.kafka.spout.KafkaSpout;
import org.apache.storm.kafka.spout.KafkaSpoutConfig;
import org.apache.storm.task.OutputCollector;
import org.apache.storm.task.TopologyContext;
import org.apache.storm.topology.OutputFieldsDeclarer;
import org.apache.storm.topology.TopologyBuilder;
import org.apache.storm.topology.base.BaseRichBolt;
import org.apache.storm.tuple.Fields;
import org.apache.storm.tuple.Tuple;
import org.apache.storm.tuple.Values;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;

import java.util.Map;
import java.util.Properties;

/**
 * Storm At-Least-Once 实验拓扑
 * 
 * 核心配置：
 * - Acker 数量：1 (开启可靠性机制)
 * - Worker 数量：4 (物理隔离)
 * - Spout 并发：1
 * - Process Bolt 并发：2
 * - Sink Bolt 并发：1
 * - 业务处理延迟：2ms (模拟计算负载)
 * 
 * 部署位置：Node 1 提交
 */
public class StormAtLeastOnceTopology {
    private static final Logger LOG = LoggerFactory.getLogger(StormAtLeastOnceTopology.class);

    public static void main(String[] args) throws Exception {
        // 1. [实验核心] Kafka Spout 配置
        KafkaSpoutConfig<String, String> spoutConfig = KafkaSpoutConfig.builder(
                "node1:9092,node2:9092,node3:9092", 
                "source_data"
            )
            .setProp(ConsumerConfig.GROUP_ID_CONFIG, "storm-exp-group")
            .setProp(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest")
            // [实验关键] 开启 At-Least-Once 可靠性保证
            .setProcessingGuarantee(KafkaSpoutConfig.ProcessingGuarantee.AT_LEAST_ONCE)
            .build();

        // 2. 构建拓扑
        TopologyBuilder builder = new TopologyBuilder();

        // [资源分配] Spout 并发=1
        builder.setSpout("kafka-spout", new KafkaSpout<>(spoutConfig), 1);

        // [资源分配] Process Bolt 并发=2
        builder.setBolt("process-bolt", new ProcessBolt(), 2)
               .shuffleGrouping("kafka-spout");
        
        // [资源分配] Sink Bolt 并发=1 (写入 Kafka storm_sink)
        builder.setBolt("sink-bolt", new KafkaSinkBolt(), 1)
               .shuffleGrouping("process-bolt");

        // 3. 拓扑配置
        Config conf = new Config();
        
        // [实验核心] 开启 Acker (1个)
        conf.setNumAckers(1);
        
        // [实验核心] 总 Worker 数 = 4 (实现物理隔离)
        conf.setNumWorkers(4);
        
        // 超时设置 60s
        conf.setMessageTimeoutSecs(60);
        
        // 性能调优
        conf.put(Config.TOPOLOGY_MAX_SPOUT_PENDING, 1000);

        LOG.info("====================================");
        LOG.info("Storm At-Least-Once Topology Submitting...");
        LOG.info("Num Ackers: 1");
        LOG.info("Num Workers: 4");
        LOG.info("Spout Parallelism: 1");
        LOG.info("Process Bolt Parallelism: 2");
        LOG.info("Sink Bolt Parallelism: 1");
        LOG.info("Source Topic: source_data");
        LOG.info("Sink Topic: storm_sink");
        LOG.info("====================================");

        // 4. 提交拓扑
        String topologyName = args.length > 0 ? args[0] : "Storm-AtLeastOnce-Test";
        StormSubmitter.submitTopology(topologyName, conf, builder.createTopology());
    }

    /**
     * 处理 Bolt - 模拟2ms计算延迟
     * 使用 BaseRichBolt 手动 ACK
     */
    public static class ProcessBolt extends BaseRichBolt {
        private static final Logger LOG = LoggerFactory.getLogger(ProcessBolt.class);
        private OutputCollector collector;
        private long processedCount = 0;

        @Override
        public void prepare(Map<String, Object> topoConf, TopologyContext context, OutputCollector collector) {
            this.collector = collector;
        }

        @Override
        public void execute(Tuple input) {
            try {
                String value = input.getStringByField("value");
                JSONObject json = JSONObject.parseObject(value);
                
                // [负载模拟] 强制休眠 2ms
                Thread.sleep(2);
                
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
                
                // [实验关键] 手动 ACK (确保可靠性)
                collector.ack(input);
                
            } catch (Exception e) {
                LOG.error("Error processing tuple", e);
                // [实验关键] 处理失败时 FAIL (触发重试)
                collector.fail(input);
            }
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
