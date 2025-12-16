#!/bin/bash
# ========================================
# Flink At-Least-Once 异常测试脚本
# 在 Node 1 执行
# 对标: start-storm-fault-test.sh（内部异常注入）
# 故障模拟：泊松分布（指数间隔）
# ========================================

echo "=== Flink At-Least-Once 异常测试 ==="

# 默认参数
MESSAGE_COUNT=${1:-100000}  # 消息总数（默认 10万）
SPEED=${2:-2000}            # 发送速率（默认 2000 msg/s）
FAULT_TYPE=${3:-none}       # 异常类型：none, before, after
FAULT_LAMBDA=${4:-10000}    # 泊松分布参数：平均每处理多少条消息发生一次故障（默认 10000）

echo "测试配置："
echo "  - 消息总数      : $MESSAGE_COUNT"
echo "  - 发送速率      : $SPEED msg/s"
echo "  - 故障类型      : $FAULT_TYPE (none/before/after)"
echo "  - Lambda (平均) : $FAULT_LAMBDA 条消息"
echo "  - 故障分布      : 泊松过程（指数间隔）"
echo ""

# 0. 复位数据库（仅清空 metrics，保留快照）
echo "[0/4] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();" 2>/dev/null
echo "✓ 数据库已复位"

# 1. 启动数据生成器（固定数量模式）
echo "[1/4] 启动数据生成器（Node 2）- 固定 $MESSAGE_COUNT 条消息..."
ssh node2 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=DataGenerator -jar data-generator.jar source_data $SPEED $MESSAGE_COUNT > generator.log 2>&1 &" && sleep 1
echo "✓ 数据生成器已启动（将生成 $MESSAGE_COUNT 条消息后自动停止）"

# 2. 提交 Flink Job（带异常注入配置）
echo "[2/4] 提交 Flink Job（异常类型: $FAULT_TYPE）..."
cd /opt/experiment

# 将脚本中的 FAULT_TYPE 映射为作业内部使用的 faultType 参数
case $FAULT_TYPE in
  before)
    JOB_FAULT_TYPE="before"
    ;;
  after)
    JOB_FAULT_TYPE="after"
    ;;
  none)
    JOB_FAULT_TYPE="none"
    ;;
  *)
    echo "错误：未知的异常类型 $FAULT_TYPE (支持: none/before/after)"
    exit 1
    ;;
esac

/opt/flink/bin/flink run -d \
  -c com.dase.bigdata.job.FlinkAtLeastOnceJobWithFaultInjection \
  experiment-job.jar \
  "$JOB_FAULT_TYPE" "$FAULT_LAMBDA"

echo "✓ Flink Job 已提交"

# 3. 启动指标收集器（Node 3）
echo "[3/4] 启动指标收集器（Node 3）..."
ssh node3 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=MetricsCollector -jar metrics-collector.jar flink_sink flink-fault-$FAULT_TYPE > collector-flink-fault.log 2>&1 &" && sleep 1
echo "✓ 指标收集器已启动"

# 4. 等待数据生成完成
echo "[4/4] 等待数据生成完成..."
EXPECTED_TIME=$((MESSAGE_COUNT / SPEED + 10))
echo "预计数据生成时间: ${EXPECTED_TIME} 秒"
echo "提示：可以在另一个终端执行以下命令查看进度："
echo "  - 查看数据生成器日志: ssh node2 'tail -f /opt/experiment/generator.log'"
echo "  - 查看 Flink UI: http://node1:8081"
echo "  - 查看数据库统计: mysql -h node1 -u exp_user -ppassword stream_experiment -e 'SELECT * FROM v_duplicate_stats;'"
echo ""
echo "=== Flink 异常测试启动完成 ==="
echo ""
echo "后续操作："
echo "1. 等待数据处理完成（建议等待 $((EXPECTED_TIME * 2)) 秒）"
echo "2. 查看测试结果: ./view-flink-fault-test-result.sh $FAULT_TYPE"
echo "3. 停止测试: ./stop-all.sh"