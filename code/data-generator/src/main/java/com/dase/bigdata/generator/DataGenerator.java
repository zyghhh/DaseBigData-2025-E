package com.dase.bigdata.generator;

import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.clients.admin.ListTopicsResult;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Collections;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.ExecutionException;

/**
 * Kafka数据生成器
 * 功能：以恒定速率产生带有时间戳和唯一ID的模拟数据
 * 部署位置：Node 2
 */
public class DataGenerator {
    private static final Logger LOG = LoggerFactory.getLogger(DataGenerator.class);

    public static void main(String[] args) {
        // 1. 配置参数 (支持命令行传参调整负载)
        String topic = args.length > 0 ? args[0] : "source_data";
        int speed = args.length > 1 ? Integer.parseInt(args[1]) : 1000; // QPS (每秒消息数)
        long maxMessages = args.length > 2 ? Long.parseLong(args[2]) : -1; // -1 表示无限模式，否则为固定数量
        long durationSeconds = args.length > 3 ? Long.parseLong(args[3]) : -1; // -1 表示无限时间，否则为运行时长（秒）

        // 初始化 Topic（确保 Topic 存在且有 4 个分区）
        String bootstrapServers = "node1:9092,node2:9092,node3:9092";
        initTopic(bootstrapServers, topic, 4, (short) 3);

        // 2. Kafka Producer 配置
        Properties props = new Properties();
        // [关键] 连接 Node 1, Node 2, Node 3
        props.put("bootstrap.servers", bootstrapServers);
        props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        
        // 性能优化配置
        props.put("acks", "1"); // 平衡可靠性和性能
        props.put("batch.size", 16384); // 批量发送
        props.put("linger.ms", 10); // 批量延迟
        props.put("compression.type", "snappy"); // 压缩

        KafkaProducer<String, String> producer = new KafkaProducer<>(props);
        long msgId = 1;

        LOG.info("====================================");
        LOG.info("Data Generator Started");
        LOG.info("Target Topic: {}", topic);
        LOG.info("Target Speed: {} msg/s", speed);
        LOG.info("Max Messages: {}", maxMessages == -1 ? "Unlimited" : maxMessages);
        LOG.info("Duration: {}", durationSeconds == -1 ? "Unlimited" : durationSeconds + "s");
        LOG.info("Kafka Brokers: node1:9092,node2:9092,node3:9092");
        LOG.info("====================================");

        // 添加优雅关闭钩子
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Shutting down producer...");
            producer.close();
            LOG.info("Producer closed successfully");
        }));

        long totalSent = 0;
        long startTime = System.currentTimeMillis();

        try {
            while (true) {
                long cycleStart = System.currentTimeMillis();
                
                // 3. 每秒发送指定数量的消息
                for (int i = 0; i < speed; i++) {
                    // [关键] 检查是否达到最大数量
                    if (maxMessages > 0 && totalSent >= maxMessages) {
                        LOG.info("Reached max messages limit: {}", maxMessages);
                        LOG.info("Total sent: {}, Running time: {}s", totalSent, (System.currentTimeMillis() - startTime) / 1000);
                        producer.flush();
                        producer.close();
                        return;
                    }
                    
                    // [关键] 检查是否达到运行时长
                    long runningTime = (System.currentTimeMillis() - startTime) / 1000;
                    if (durationSeconds > 0 && runningTime >= durationSeconds) {
                        LOG.info("Reached duration limit: {}s", durationSeconds);
                        LOG.info("Total sent: {}, Running time: {}s", totalSent, runningTime);
                        producer.flush();
                        producer.close();
                        return;
                    }
                    
                    // 构造消息 JSON
                    JSONObject json = new JSONObject();
                    json.put("msg_id", msgId);
                    json.put("create_time", System.currentTimeMillis());
                    // 填充 Payload 模拟 1KB 数据
                    json.put("payload", generatePayload(1000));

                    // 保存当前消息ID（Lambda 表达式需要 final 变量）
                    final long currentMsgId = msgId;
                    
                    // 异步发送到 Kafka
                    producer.send(new ProducerRecord<>(topic, String.valueOf(msgId), json.toJSONString()), 
                        (metadata, exception) -> {
                            if (exception != null) {
                                LOG.error("Failed to send message {}: {}", currentMsgId, exception.getMessage());
                            }
                        });
                    
                    msgId++;
                    totalSent++;
                }
                
                // 4. 流控：精确控制 QPS
                long elapsed = System.currentTimeMillis() - cycleStart;
                if (elapsed < 1000) {
                    try {
                        Thread.sleep(1000 - elapsed);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }

                // 5. 定期打印统计信息 (每10秒)
                if (totalSent % (speed * 10) == 0) {
                    long runningTime = (System.currentTimeMillis() - startTime) / 1000;
                    double actualSpeed = totalSent / (double) runningTime;
                    LOG.info("Statistics: Total Sent={}, Running Time={}s, Actual Speed={} msg/s", 
                        totalSent, runningTime, String.format("%.2f", actualSpeed));
                }
            }
        } catch (Exception e) {
            LOG.error("Generator encountered error", e);
        } finally {
            producer.close();
        }
    }

    /**
     * 初始化 Kafka Topic（如果不存在则创建）
     * @param bootstrapServers Kafka 集群地址
     * @param topicName Topic 名称
     * @param numPartitions 分区数
     * @param replicationFactor 副本因子
     */
    private static void initTopic(String bootstrapServers, String topicName, int numPartitions, short replicationFactor) {
        Properties adminProps = new Properties();
        adminProps.put("bootstrap.servers", bootstrapServers);
        
        try (AdminClient adminClient = AdminClient.create(adminProps)) {
            // 检查 Topic 是否存在
            ListTopicsResult listTopics = adminClient.listTopics();
            Set<String> existingTopics = listTopics.names().get();
            
            if (existingTopics.contains(topicName)) {
                LOG.info("Topic '{}' already exists, skipping creation", topicName);
            } else {
                // 创建 Topic
                NewTopic newTopic = new NewTopic(topicName, numPartitions, replicationFactor);
                adminClient.createTopics(Collections.singletonList(newTopic)).all().get();
                LOG.info("Topic '{}' created successfully with {} partitions and replication factor {}", 
                    topicName, numPartitions, replicationFactor);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            LOG.error("Topic initialization was interrupted", e);
            throw new RuntimeException("Failed to initialize topic", e);
        } catch (ExecutionException e) {
            LOG.error("Failed to initialize topic '{}'", topicName, e);
            throw new RuntimeException("Failed to initialize topic", e);
        }
    }

    /**
     * 生成指定大小的 Payload
     * @param sizeInBytes 目标大小（字节）
     * @return Payload 字符串
     */
    private static String generatePayload(int sizeInBytes) {
        StringBuilder sb = new StringBuilder(sizeInBytes);
        for (int i = 0; i < sizeInBytes; i++) {
            sb.append('x');
        }
        return sb.toString();
    }
}
