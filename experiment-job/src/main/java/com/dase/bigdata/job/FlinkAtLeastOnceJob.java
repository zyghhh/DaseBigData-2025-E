package com.dase.bigdata.job;

import com.alibaba.fastjson.JSONObject;
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.connectors.kafka.FlinkKafkaConsumer;
import org.apache.flink.streaming.connectors.kafka.FlinkKafkaProducer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Properties;

/**
 * Flink At-Least-Once 实验任务
 * 
 * 核心配置：
 * - Checkpoint 间隔：5秒
 * - Checkpoint 模式：AT_LEAST_ONCE
 * - 并发度：4 (对齐 TaskManager Slots)
 * - 业务处理延迟：2ms (模拟计算负载)
 * 
 * 部署位置：Node 1 提交
 */
public class FlinkAtLeastOnceJob {
    private static final Logger LOG = LoggerFactory.getLogger(FlinkAtLeastOnceJob.class);

    public static void main(String[] args) throws Exception {
        // 1. 创建执行环境
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // 2. [实验核心] 开启 Checkpoint (5秒一次)
        env.enableCheckpointing(5000);
        env.getCheckpointConfig().setCheckpointingMode(CheckpointingMode.AT_LEAST_ONCE);
        
        // Checkpoint 高级配置
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(500); // 两次checkpoint最小间隔
        env.getCheckpointConfig().setCheckpointTimeout(60000); // checkpoint超时时间60s
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1); // 同时最多1个checkpoint
        
        // 3. [资源对齐] 保持并发度与 Slot 一致
        env.setParallelism(4);

        // 4. Kafka Source 配置
        Properties sourceProps = new Properties();
        sourceProps.setProperty("bootstrap.servers", "node1:9092,node2:9092,node3:9092");
        sourceProps.setProperty("group.id", "flink-exp-group");
        // [实验关键] 自动提交 offset (配合 Checkpoint)
        sourceProps.setProperty("enable.auto.commit", "true");
        sourceProps.setProperty("auto.commit.interval.ms", "5000");

        FlinkKafkaConsumer<String> consumer = new FlinkKafkaConsumer<>(
            "source_data", 
            new SimpleStringSchema(), 
            sourceProps
        );
        // 从最早的记录开始读取（首次运行）
        // consumer.setStartFromEarliest();

        // 5. Kafka Sink 配置
        Properties sinkProps = new Properties();
        sinkProps.setProperty("bootstrap.servers", "node1:9092,node2:9092,node3:9092");
        
        FlinkKafkaProducer<String> producer = new FlinkKafkaProducer<>(
            "flink_sink",
            new SimpleStringSchema(),
            sinkProps
        );

        // 6. 构建数据流
        env.addSource(consumer)
           .name("Kafka Source")
           .map(new ProcessMapFunction())
           .name("Business Logic (2ms delay)")
           .addSink(producer)
           .name("Kafka Sink");

        LOG.info("====================================");
        LOG.info("Flink At-Least-Once Job Starting...");
        LOG.info("Checkpoint Interval: 5000ms");
        LOG.info("Checkpoint Mode: AT_LEAST_ONCE");
        LOG.info("Parallelism: 4");
        LOG.info("Source Topic: source_data");
        LOG.info("Sink Topic: flink_sink");
        LOG.info("====================================");

        // 7. 执行任务
        env.execute("Flink At-Least-Once Test");
    }

    /**
     * 业务处理函数 - 模拟2ms计算延迟
     */
    public static class ProcessMapFunction implements MapFunction<String, String> {
        private static final Logger LOG = LoggerFactory.getLogger(ProcessMapFunction.class);
        private long processedCount = 0;

        @Override
        public String map(String value) throws Exception {
            try {
                JSONObject json = JSONObject.parseObject(value);
                
                // [负载模拟] 强制休眠 2ms
                Thread.sleep(2);
                
                // 打上处理时间
                json.put("process_time", System.currentTimeMillis());
                json.put("processor", "flink");
                
                processedCount++;
                
                // 定期打印处理进度
                if (processedCount % 10000 == 0) {
                    LOG.info("Processed {} messages", processedCount);
                }
                
                return json.toJSONString();
            } catch (Exception e) {
                LOG.error("Error processing message: {}", value, e);
                throw e;
            }
        }
    }
}
