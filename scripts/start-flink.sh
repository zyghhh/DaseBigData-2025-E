#!/bin/bash
set -e

# ========================================
# 启动 Flink 实验 - 在 Node 1 执行
# ========================================

echo "=== 启动 Flink 实验 ==="

# 0. 复位数据库
echo "[0/3] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment \
  -e "CALL sp_reset_experiment();" >/dev/null
echo "✓ 数据库已复位"

# 1. 启动数据生成器（Node 2）
echo "[1/3] 启动数据生成器（Node 2）..."
ssh node2 "
  cd /opt/experiment &&
  setsid nohup java -Xmx512m -Dapp.name=DataGenerator \
    -jar data-generator.jar source_data 1500 \
    > generator.log 2>&1 < /dev/null &
  echo '✓ generator started'
"
sleep 1

# 2. 提交 Flink Job（本地 Node 1）
echo "[2/3] 提交 Flink Job..."
cd /opt/experiment
/opt/flink/bin/flink run -d -c com.dase.bigdata.job.FlinkAtLeastOnceJob experiment-job.jar
echo "✓ Flink Job 已提交"

# 3. 启动指标收集器（Node 3）
echo "[3/3] 启动指标收集器（Node 3）..."
ssh node3 "
  cd /opt/experiment &&
  setsid nohup java -Xmx512m -Dapp.name=MetricsCollector \
    -jar metrics-collector.jar flink_sink flink \
    > collector-flink.log 2>&1 < /dev/null &
  echo '✓ collector started'
"

echo ""
echo "=== Flink 实验已启动 ==="
echo "查看状态: ./bin/flink list"
echo "Web UI: http://node1:8081"
