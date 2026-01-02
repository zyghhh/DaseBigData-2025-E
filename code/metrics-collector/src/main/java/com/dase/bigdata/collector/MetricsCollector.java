package com.dase.bigdata.collector;

import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.time.Duration;
import java.util.Collections;
import java.util.Properties;

/**
 * 指标收集器
 * 
 * 功能：
 * - 消费 Kafka Sink Topic (flink_sink 或 storm_sink)
 * - 计算端到端延迟 (出队时间 - 创建时间)
 * - 利用 MySQL 主键约束统计重复率
 * - 实时写入 MySQL 数据库
 * 
 * 部署位置：Node 3
 */
public class MetricsCollector {
    private static final Logger LOG = LoggerFactory.getLogger(MetricsCollector.class);

    // 数据库配置 (可通过配置文件外部化)
    private static final String DB_URL = "jdbc:mysql://node1:3306/stream_experiment?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC";
    private static final String DB_USER = "exp_user";
    private static final String DB_PASSWORD = "password";

    public static void main(String[] args) {
        if (args.length < 2) {
            LOG.error("Usage: java -jar metrics-collector.jar <topic> <jobType>");
            LOG.error("Example: java -jar metrics-collector.jar flink_sink flink");
            System.exit(1);
        }

        String topic = args[0];      // flink_sink 或 storm_sink
        String jobType = args[1];    // flink 或 storm

        LOG.info("====================================");
        LOG.info("Metrics Collector Started");
        LOG.info("Consuming Topic: {}", topic);
        LOG.info("Job Type: {}", jobType);
        LOG.info("Database: {}", DB_URL);
        LOG.info("====================================");

        // 1. Kafka Consumer 配置
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "node1:9092,node2:9092,node3:9092");
        props.put(ConsumerConfig.GROUP_ID_CONFIG, jobType + "-metrics-collector");
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.StringDeserializer");
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, "org.apache.kafka.common.serialization.StringDeserializer");
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "true");
        props.put(ConsumerConfig.AUTO_COMMIT_INTERVAL_MS_CONFIG, "1000");
        
        KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props);
        consumer.subscribe(Collections.singletonList(topic));

        // 2. 初始化数据库连接
        Connection conn = null;
        PreparedStatement ps = null;
        
        try {
            // 加载 MySQL 驱动
            Class.forName("com.mysql.cj.jdbc.Driver");
            
            conn = DriverManager.getConnection(DB_URL, DB_USER, DB_PASSWORD);
            conn.setAutoCommit(false); // 使用手动提交，批量优化
            
            LOG.info("Database connection established");

            // [实验核心] 幂等插入 SQL - 利用主键冲突检测重复
            String sql = "INSERT INTO metrics (job_type, msg_id, event_time, out_time, latency, process_count) " +
                         "VALUES (?, ?, ?, ?, ?, 1) " +
                         "ON DUPLICATE KEY UPDATE " +
                         "process_count = process_count + 1, " +
                         "out_time = VALUES(out_time), " +
                         "latency = VALUES(latency)";
            
            ps = conn.prepareStatement(sql);

            long recordCount = 0;
            long batchSize = 0;
            long totalLatency = 0;
            long minLatency = Long.MAX_VALUE;
            long maxLatency = Long.MIN_VALUE;

            // 添加优雅关闭钩子
            final Connection finalConn = conn;
            final PreparedStatement finalPs = ps;
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                LOG.info("Shutting down collector...");
                try {
                    if (finalPs != null) finalPs.close();
                    if (finalConn != null) finalConn.close();
                    consumer.close();
                } catch (SQLException e) {
                    LOG.error("Error during shutdown", e);
                }
                LOG.info("Collector closed successfully");
            }));

            // 3. 持续消费消息并写入数据库
            while (true) {
                ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
                
                for (ConsumerRecord<String, String> record : records) {
                    try {
                        JSONObject json = JSONObject.parseObject(record.value());
                        
                        long msgId = json.getLongValue("msg_id");
                        long eventTime = json.getLongValue("create_time");
                        long processTime = json.getLongValue("process_time");
                        long outTime = System.currentTimeMillis();
                        long latency = outTime - eventTime; // 端到端延迟

                        // 准备批量插入
                        ps.setString(1, jobType);
                        ps.setLong(2, msgId);
                        ps.setLong(3, eventTime);
                        ps.setLong(4, outTime);
                        ps.setLong(5, latency);
                        
                        ps.addBatch();
                        batchSize++;
                        recordCount++;

                        // 统计延迟
                        totalLatency += latency;
                        minLatency = Math.min(minLatency, latency);
                        maxLatency = Math.max(maxLatency, latency);

                    } catch (Exception e) {
                        LOG.error("Error processing record: {}", record.value(), e);
                    }
                }

                // 4. 批量提交到数据库 (每100条或每次poll后)
                if (batchSize > 0) {
                    try {
                        ps.executeBatch();
                        conn.commit();
                        batchSize = 0;
                    } catch (SQLException e) {
                        LOG.error("Error executing batch", e);
                        conn.rollback();
                    }
                }

                // 5. 定期打印统计信息 (每10000条)
                if (recordCount > 0 && recordCount % 10000 == 0) {
                    double avgLatency = totalLatency / (double) recordCount;
                    LOG.info("===== Statistics =====");
                    LOG.info("Total Records: {}", recordCount);
                    LOG.info("Avg Latency: {} ms", String.format("%.2f", avgLatency));
                    LOG.info("Min Latency: {} ms", minLatency);
                    LOG.info("Max Latency: {} ms", maxLatency);
                    LOG.info("=====================");
                }
            }

        } catch (Exception e) {
            LOG.error("Collector encountered fatal error", e);
        } finally {
            // 清理资源
            try {
                if (ps != null) ps.close();
                if (conn != null) conn.close();
                consumer.close();
            } catch (SQLException e) {
                LOG.error("Error closing resources", e);
            }
        }
    }
}
