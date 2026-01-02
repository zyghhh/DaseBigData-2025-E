#!/bin/bash

# ==========================
# 一键清空 Kafka + Flink 实验环境
# ==========================

# Kafka 节点列表
KAFKA_NODES=("node1" "node2" "node3")
KAFKA_PATH="/root/kafka"
KAFKA_DATA_DIR="/root/kafka/data"

# Flink checkpoint / savepoint 目录
FLINK_CHECKPOINT_DIR="/tmp/flink-checkpoints"
FLINK_SAVEPOINT_DIR="/tmp/flink-savepoints"

# --------------------------
# 1. 停止 Flink 作业
# --------------------------
echo "Stopping Flink jobs..."
flink list -r | awk '{if(NR>1) print $1}' | xargs -r flink cancel
echo "Flink jobs stopped."

# --------------------------
# 2. 停止 Kafka 集群
# --------------------------
echo "Stopping Kafka brokers..."
for node in "${KAFKA_NODES[@]}"; do
    ssh "$node" "cd $KAFKA_PATH && bin/kafka-server-stop.sh"
done
echo "Kafka brokers stopped."

# --------------------------
# 3. 清空 Kafka 数据
# --------------------------
echo "Cleaning Kafka data directories..."
for node in "${KAFKA_NODES[@]}"; do
    ssh "$node" "rm -rf ${KAFKA_DATA_DIR}/*"
done
echo "Kafka data cleaned."

# --------------------------
# 4. 清空 Flink Checkpoint / Savepoint
# --------------------------
echo "Cleaning Flink checkpoints and savepoints..."
rm -rf "$FLINK_CHECKPOINT_DIR"/*
rm -rf "$FLINK_SAVEPOINT_DIR"/*
echo "Flink state cleared."

# --------------------------
# 5. 启动 Kafka 集群
# --------------------------
echo "Starting Kafka brokers..."
for node in "${KAFKA_NODES[@]}"; do
    ssh "$node" "cd $KAFKA_PATH && bin/kafka-server-start.sh -daemon config/server.properties"
done
echo "Kafka brokers started."

# --------------------------
# 6. 提示操作完成
# --------------------------
echo "==================================="
echo "Kafka + Flink 实验环境已清空并重置完成！"
echo "请重新创建 topic 并启动 Flink / Storm 作业。"
echo "==================================="
