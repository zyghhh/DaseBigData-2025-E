#!/bin/bash
set -e

QPS=${1:-1500}          # 每秒消息数
TOTAL_MESSAGES=${2:--1} # -1 表示一直发送，否则为固定总条数

echo "=== 启动 Storm 实验 ==="

# 0. 检查并保存上次实验结果
echo "[0/4] 检查上次实验数据..."
ROW_COUNT=$(mysql -h node1 -u exp_user -ppassword stream_experiment \
  -se "SELECT COUNT(*) FROM metrics WHERE job_type='storm';" 2>/dev/null)

if [ "$ROW_COUNT" -gt 0 ]; then
  echo "⚠ 发现上次实验数据 ($ROW_COUNT 条记录)"
  read -p "是否创建快照保存结果? [Y/n]: " CREATE_SNAP
  CREATE_SNAP=${CREATE_SNAP:-Y}
  
  if [[ "$CREATE_SNAP" =~ ^[Yy]$ ]]; then
    read -p "请输入快照描述 (留空使用默认): " SNAP_NOTE
    SNAP_NOTE=${SNAP_NOTE:-"Storm实验-$(date +'%Y%m%d-%H%M%S')"}
    
    echo "正在创建快照..."
    mysql -h node1 -u exp_user -ppassword stream_experiment \
      -e "CALL sp_create_snapshot('$SNAP_NOTE');" 2>/dev/null | tail -n +2
    echo "✓ 快照已保存"
  else
    echo "⚠ 跳过快照创建，上次实验数据将丢失"
  fi
fi

echo "[1/4] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment \
  -e "TRUNCATE TABLE metrics;" >/dev/null 2>&1
echo "✓ 数据库已复位"

echo "[2/4] 启动数据生成器（Node 2）..."
ssh node2 "
  cd /opt/experiment &&
  setsid nohup java -Xmx512m -Dapp.name=DataGenerator \
    -jar data-generator.jar source_data $QPS $TOTAL_MESSAGES \
    > generator.log 2>&1 < /dev/null &
  echo '✓ generator started'
"
sleep 1

echo "[3/4] 提交 Storm Topology..."
cd /opt/experiment
/opt/storm/bin/storm jar experiment-job.jar \
  com.dase.bigdata.job.StormAtLeastOnceTopology Storm-Test
echo "✓ Storm Topology 已提交"

echo "[4/4] 启动指标收集器（Node 3）..."
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
