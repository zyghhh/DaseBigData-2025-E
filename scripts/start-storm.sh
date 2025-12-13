#!/bin/bash
set -e

echo "=== 启动 Storm 实验 ==="

echo "[0/3] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment \
  -e "CALL sp_reset_experiment();" >/dev/null
echo "✓ 数据库已复位"

echo "[1/3] 启动数据生成器（Node 2）..."
ssh node2 "
  cd /opt/experiment &&
  setsid nohup java -Xmx512m -Dapp.name=DataGenerator \
    -jar data-generator.jar source_data 1500 \
    > generator.log 2>&1 < /dev/null &
  echo '✓ generator started'
"
sleep 1

echo "[2/3] 提交 Storm Topology..."
cd /opt/experiment
/opt/storm/bin/storm jar experiment-job.jar \
  com.dase.bigdata.job.StormAtLeastOnceTopology Storm-Test
echo "✓ Storm Topology 已提交"

echo "[3/3] 启动指标收集器（Node 3）..."
ssh node3 "
  cd /opt/experiment &&
  setsid nohup java -Xmx512m -Dapp.name=MetricsCollector \
    -jar metrics-collector.jar storm_sink storm \
    > collector-storm.log 2>&1 < /dev/null &
  echo '✓ collector started'
"

echo ""
echo "=== Storm 实验已启动 ==="
echo "Web UI: http://node1:8080"
