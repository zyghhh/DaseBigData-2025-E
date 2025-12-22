#!/bin/bash
# ========================================
# Storm At-Least-Once 异常测试脚本
# 在 Node 1 执行
# 故障模拟：泊松分布（指数间隔）
# ========================================

echo "=== Storm At-Least-Once 异常测试 ==="

# 默认参数
MESSAGE_COUNT=${1:-100000}  # 消息总数（默认 10万）
SPEED=${2:-2000}             # 发送速率（默认 2000 msg/s）
MAX_PENDING=${3:-1000}       # Spout Max Pending（默认 1000）
FAULT_TYPE=${4:-none}        # 异常类型：none, spout, bolt-before, bolt-after, acker
FAULT_LAMBDA=${5:-10000}     # 泊松分布参数：平均每处理多少条消息发生一次故障（默认 10000）

echo "测试配置："
echo "  - 消息总数: $MESSAGE_COUNT"
echo "  - 发送速率: $SPEED msg/s"
echo "  - Spout Max Pending: $MAX_PENDING"
echo "  - 异常类型: $FAULT_TYPE"
echo "  - Lambda (平均): $FAULT_LAMBDA 条消息"
echo "  - 故障分布: 泊松过程（指数间隔）"
echo ""

# 0. 复位数据库
echo "[0/4] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();" 2>/dev/null
echo "✓ 数据库已复位"

# 1. 启动数据生成器（固定数量模式）
echo "[1/4] 启动数据生成器（Node 2）- 固定 $MESSAGE_COUNT 条消息..."
ssh node2 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=DataGenerator -jar data-generator.jar source_data $SPEED $MESSAGE_COUNT > generator.log 2>&1 &"
echo "✓ 数据生成器已启动（将生成 $MESSAGE_COUNT 条消息后自动停止）"

# 2. 提交 Storm Topology（带异常注入配置）
echo "[2/4] 提交 Storm Topology（异常类型: $FAULT_TYPE）..."
cd /opt/experiment

# 根据异常类型设置 JVM 参数
case $FAULT_TYPE in
  spout)
    FAULT_OPTS="-Dfault.spout.enabled=true -Dfault.lambda=$FAULT_LAMBDA"
    ;;
  bolt-before)
    FAULT_OPTS="-Dfault.bolt.enabled=true -Dfault.bolt.before.emit=true -Dfault.lambda=$FAULT_LAMBDA"
    ;;
  bolt-after)
    FAULT_OPTS="-Dfault.bolt.enabled=true -Dfault.bolt.before.emit=false -Dfault.lambda=$FAULT_LAMBDA"
    ;;
  none)
    FAULT_OPTS=""
    ;;
  *)
    echo "错误：未知的异常类型 $FAULT_TYPE"
    exit 1
    ;;
esac

# 提交拓扑
/opt/storm/bin/storm jar experiment-job.jar \
  -Dspout.max.pending=$MAX_PENDING \
  $FAULT_OPTS \
  com.dase.bigdata.job.StormAtLeastOnceTopologyWithFaultInjection \
  Storm-FaultTest-$FAULT_TYPE

echo "✓ Storm Topology 已提交"

# 3. 启动指标收集器（Node 3）
echo "[3/4] 启动指标收集器（Node 3）..."
ssh node3 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=MetricsCollector -jar metrics-collector.jar storm_sink storm-fault-$FAULT_TYPE > collector-storm-fault.log 2>&1 &" && sleep 1
echo "✓ 指标收集器已启动"

# 4. 等待数据生成完成
EXPECTED_TIME=$((MESSAGE_COUNT / SPEED + 10))
echo "[4/4] 等待数据生成完成（预计 $EXPECTED_TIME 秒）..."
echo "提示：可以在另一个终端执行以下命令查看进度："
echo "  - 查看数据生成器日志: ssh node2 'tail -f /opt/experiment/generator.log'"
echo "  - 查看 Storm UI: http://node1:8080"
echo "  - 查看数据库统计: mysql -h node1 -u exp_user -ppassword stream_experiment -e 'SELECT * FROM v_duplicate_stats;'"
echo ""
echo "=== 测试启动完成 ==="
echo ""
echo "后续操作："
echo "1. 等待数据处理完成（建议等待 $((EXPECTED_TIME * 2)) 秒）"
echo "2. 查看测试结果: ./view-fault-test-result.sh $FAULT_TYPE"
echo "3. 停止测试: ./stop-all.sh"
echo ""

# 可选：人工 Kill 进程测试
if [ "$FAULT_TYPE" == "acker" ]; then
  echo "提示：异常类型为 'acker'，需要手动 Kill Acker 进程来测试"
  echo "执行命令："
  echo "  1. 查找 Acker 进程: ps aux | grep storm | grep acker"
  echo "  2. Kill 进程: kill -9 <PID>"
  echo "  3. 重复多次以模拟多次异常"
  echo ""
fi
