package com.dase.bigdata.job;

import com.alibaba.fastjson.JSONObject;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Properties;
import java.util.Random;

/**
 * Flink At-Least-Once 实验任务（带内部异常注入）
 *
 * 核心配置与 {@link FlinkAtLeastOnceJob} 保持一致：
 * - Checkpoint 间隔：5秒
 * - Checkpoint 模式：AT_LEAST_ONCE
 * - 并发度：4
 * - 业务处理延迟：1ms
 *
 * 额外支持的故障注入参数（通过 main(args) 传入）：
 * - args[0] faultType: "none" / "before" / "after"
 * - args[1] lambda: 泊松分布参数，平均每处理多少条消息发生一次故障（默认 10000）
 *              例如：lambda=5000 表示平均每5000条消息发生一次故障
 *              故障间隔服从指数分布，更符合真实故障场景
 */
public class FlinkAtLeastOnceJobWithFaultInjection {
    private static final Logger LOG = LoggerFactory.getLogger(FlinkAtLeastOnceJobWithFaultInjection.class);

    public static void main(String[] args) throws Exception {
        // 0. 解析故障注入配置
        String faultType = args.length > 0 ? args[0] : "none"; // none / before / after
        double faultRate = 0.0;
        if (args.length > 1) {
            try {
                faultRate = Double.parseDouble(args[1]);
            } catch (NumberFormatException e) {
                LOG.warn("Invalid faultRate '{}', fallback to 0.0", args[1]);
                faultRate = 0.0;
            }
        }

        boolean faultEnabled = !"none".equalsIgnoreCase(faultType) && faultRate > 0.0;

        LOG.info("====================================");
        LOG.info("Flink At-Least-Once Job (Fault Injection) Starting...");
        LOG.info("Fault Enabled: {}", faultEnabled);
        LOG.info("Fault Type   : {} (before / after)", faultType);
        LOG.info("Lambda (Avg) : {} messages", faultRate);
        LOG.info("Distribution : Poisson Process (Exponential Interval)");
        LOG.info("====================================");

        // 1. 创建执行环境
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // 2. Checkpoint 配置（与基线实验一致）
        env.enableCheckpointing(5000);
        env.getCheckpointConfig().setCheckpointingMode(CheckpointingMode.AT_LEAST_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(500);
        env.getCheckpointConfig().setCheckpointTimeout(60000);
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);

        // 3. 并发度对齐
        env.setParallelism(4);

        // 4. Kafka Source 配置（使用新 API）
        Properties sourceProps = new Properties();
        sourceProps.setProperty("enable.auto.commit", "true");
        sourceProps.setProperty("auto.commit.interval.ms", "5000");

        KafkaSource<String> source = KafkaSource.<String>builder()
            .setBootstrapServers("node1:9092,node2:9092,node3:9092")
            .setTopics("source_data")
            .setGroupId("flink-fault-exp-group")
            .setProperties(sourceProps)
            .setStartingOffsets(OffsetsInitializer.earliest())
            .setValueOnlyDeserializer(new SimpleStringSchema())
            .build();

        // 5. Kafka Sink 配置（使用新 API）
        KafkaSink<String> sink = KafkaSink.<String>builder()
            .setBootstrapServers("node1:9092,node2:9092,node3:9092")
            .setRecordSerializer(KafkaRecordSerializationSchema.builder()
                .setTopic("flink_sink")
                .setValueSerializationSchema(new SimpleStringSchema())
                .build()
            )
            .build();

        // 6. 构建数据流（带故障注入的 MapFunction）
        env.fromSource(source, WatermarkStrategy.noWatermarks(), "Kafka Source")
           .map(new FaultInjectionMapFunction(faultType, faultRate))
           .name("Business Logic (2ms delay + fault)")
           .sinkTo(sink)
           .name("Kafka Sink");

        LOG.info("Checkpoint Interval: 5000ms");
        LOG.info("Checkpoint Mode    : AT_LEAST_ONCE");
        LOG.info("Parallelism        : 4");
        LOG.info("Source Topic       : source_data");
        LOG.info("Sink Topic         : flink_sink");
        LOG.info("====================================");

        env.execute("Flink At-Least-Once Fault Injection Test");
    }

    /**
     * 带故障注入的业务处理函数：
     * - 使用泊松分布模拟故障发生，更接近真实场景
     * - faultRate 表示平均每处理多少条消息发生一次故障（λ参数）
     */
    public static class FaultInjectionMapFunction implements MapFunction<String, String> {
        private static final Logger LOG = LoggerFactory.getLogger(FaultInjectionMapFunction.class);

        private final String faultType;   // none / before / after
        private final double lambda;      // 泊松分布参数：平均故障间隔（消息数）
        private final boolean faultEnabled;
        private final Random random = new Random();

        private long processedCount = 0;
        private long nextFaultAt = -1;    // 下一次故障发生的消息序号

        public FaultInjectionMapFunction(String faultType, double faultRate) {
            this.faultType = faultType == null ? "none" : faultType.toLowerCase();
            this.lambda = faultRate > 0 ? faultRate : 10000.0; // 默认每10000条发生一次
            this.faultEnabled = !"none".equalsIgnoreCase(this.faultType) && faultRate > 0.0;

            if (this.faultEnabled) {
                // 初始化第一个故障点（基于泊松分布）
                this.nextFaultAt = generateNextFaultInterval();
            }

            LOG.info("FaultInjectionMapFunction initialized:");
            LOG.info("  - faultEnabled = {}", this.faultEnabled);
            LOG.info("  - faultType    = {}", this.faultType);
            LOG.info("  - lambda (avg interval) = {}", this.lambda);
            if (this.faultEnabled) {
                LOG.info("  - First fault scheduled at message #{}", this.nextFaultAt);
            }
        }

        @Override
        public String map(String value) throws Exception {
            try {
                JSONObject json = JSONObject.parseObject(value);

                // [异常注入点 1] 业务逻辑执行之前
                if (faultEnabled && "before".equals(faultType) && shouldInjectFault()) {
                    LOG.warn("Injecting fault BEFORE business logic for msg_id: {}", json.getLong("msg_id"));
                    throw new RuntimeException("Injected fault before business logic");
                }

                // [负载模拟] 强制休眠 2ms
                Thread.sleep(1);

                // 打上处理时间和标识
                json.put("process_time", System.currentTimeMillis());
                json.put("processor", "flink");

                processedCount++;
                if (processedCount % 10000 == 0) {
                    LOG.info("Processed {} messages", processedCount);
                }

                // [异常注入点 2] 业务逻辑执行之后
                if (faultEnabled && "after".equals(faultType) && shouldInjectFault()) {
                    LOG.warn("Injecting fault AFTER business logic for msg_id: {}", json.getLong("msg_id"));
                    throw new RuntimeException("Injected fault after business logic");
                }

                return json.toJSONString();
            } catch (Exception e) {
                LOG.error("Error processing message: {}", value, e);
                // 抛出让 Flink 触发 Task 重启与数据重放
                throw e;
            }
        }

        /**
         * 判断当前消息是否应该注入故障（基于泊松分布）
         */
        private boolean shouldInjectFault() {
            if (!faultEnabled) {
                return false;
            }

            // 检查是否到达故障点
            if (processedCount >= nextFaultAt) {
                // 生成下一个故障点
                nextFaultAt = processedCount + generateNextFaultInterval();
                LOG.info("Fault triggered at message #{}, next fault scheduled at #{}", 
                         processedCount, nextFaultAt);
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
    }
}
