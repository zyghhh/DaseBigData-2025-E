package com.dase.bigdata.generator;

import com.alibaba.fastjson.JSONObject;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Properties;

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

        // 2. Kafka Producer 配置
        Properties props = new Properties();
        // [关键] 连接 Node 1, Node 2, Node 3
        props.put("bootstrap.servers", "node1:9092,node2:9092,node3:9092");
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
        LOG.info("Max Messages: {}", maxMessages == -1 ? "Unlimited (Continuous Mode)" : maxMessages);
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
