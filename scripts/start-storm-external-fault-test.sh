#!/bin/bash
# ========================================
# Storm At-Least-Once 外部故障测试脚本
# 在 Node 1 执行
# 对标: start-flink-external-fault-test.sh
# 故障类型: Kill Storm Worker（自动重调度）
# ========================================

echo "=== Storm At-Least-Once 外部故障测试 ==="

# 默认参数
MESSAGE_COUNT=${1:-100000}      # 消息总数（默认 10万）
SPEED=${2:-2000}                # 发送速率（默认 2000 msg/s）
MAX_PENDING=${3:-1000}          # Spout Max Pending（默认 1000）
FAULT_DELAY=${4:-30}            # 故障延迟时间（默认实验启动后 30 秒）
FAULT_REPEAT=${5:-3}            # 故障重复次数（默认 3 次）
FAULT_INTERVAL=${6:-30}         # 故障间隔时间（默认 30 秒）

echo "测试配置："
echo "  - 消息总数      : $MESSAGE_COUNT"
echo "  - 发送速率      : $SPEED msg/s"
echo "  - Spout Max Pending: $MAX_PENDING"
echo "  - 故障延迟      : ${FAULT_DELAY}s（实验启动后等待时间）"
echo "  - 故障次数      : $FAULT_REPEAT 次"
echo "  - 故障间隔      : ${FAULT_INTERVAL}s"
echo "  - 故障类型      : Kill Storm Worker（Nimbus自动重调度）"
echo ""

# 0. 复位数据库
echo "[0/5] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();" 2>/dev/null
echo "✓ 数据库已复位"

# 1. 启动数据生成器（固定数量模式）
echo "[1/5] 启动数据生成器（Node 2）- 固定 $MESSAGE_COUNT 条消息..."
ssh node2 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=DataGenerator -jar data-generator.jar source_data $SPEED $MESSAGE_COUNT > generator.log 2>&1 &" && sleep 1
echo "✓ 数据生成器已启动（将生成 $MESSAGE_COUNT 条消息后自动停止）"

# 2. 提交 Storm Topology（正常版本，无内部故障注入）
echo "[2/5] 提交 Storm Topology（正常版本）..."
cd /opt/experiment

/opt/storm/bin/storm jar experiment-job.jar \
  -Dspout.max.pending=$MAX_PENDING \
  com.dase.bigdata.job.StormAtLeastOnceTopology \
  Storm-ExternalFaultTest

echo "✓ Storm Topology 已提交"

# 3. 启动指标收集器（Node 3）
echo "[3/5] 启动指标收集器（Node 3）..."
ssh node3 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=MetricsCollector -jar metrics-collector.jar storm_sink storm-external-fault > collector-storm-external.log 2>&1 &" && sleep 1
echo "✓ 指标收集器已启动"

# 4. 创建故障前快照
echo "[4/5] 创建故障前快照..."
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_create_snapshot('Storm-外部故障前基线-$(date +'%Y%m%d-%H%M%S')');
" 2>/dev/null | tail -n +2

# 5. 等待后自动注入故障
echo "[5/5] 等待 ${FAULT_DELAY} 秒后开始注入故障..."
sleep $FAULT_DELAY

echo ""
echo "=========================================="
echo "  开始注入外部故障（Kill Worker）"
echo "=========================================="

LOG_FILE="/opt/experiment/fault-injection-storm-log.csv"

for i in $(seq 1 $FAULT_REPEAT); do
    echo ""
    echo "======== 故障注入 #${i}/${FAULT_REPEAT} ========"
    INJECT_TIME=$(date +'%Y-%m-%d %H:%M:%S')
    
    # 查找 Worker 进程
    WORKER_PIDS=$(ps aux | grep storm | grep worker | grep -v grep | awk '{print $2}')
    
    if [ -z "$WORKER_PIDS" ]; then
        echo "⚠ 警告: 未找到 Storm Worker 进程"
    else
        # 随机选择一个 Worker
        TARGET_PID=$(echo "$WORKER_PIDS" | shuf -n 1)
        echo "[${INJECT_TIME}] Target Worker PID: $TARGET_PID"
        
        # 记录故障
        echo "$INJECT_TIME,kill-worker,$TARGET_PID" >> "$LOG_FILE"
        
        # Kill 进程
        kill -9 $TARGET_PID
        echo "✓ Worker (PID: $TARGET_PID) 已被 Kill"
        
        # Storm 会自动重新调度任务
        echo "等待 Storm Nimbus 重新调度 Worker（约 15 秒）..."
        sleep 15
        
        # 验证 Worker 是否恢复
        NEW_WORKER_COUNT=$(ps aux | grep storm | grep worker | grep -v grep | wc -l)
        if [ $NEW_WORKER_COUNT -gt 0 ]; then
            echo "✓ Storm Worker 已被 Nimbus 重新调度"
        else
            echo "✗ Worker 未恢复，请检查 Nimbus 状态"
        fi
    fi
    
    # 创建故障后快照
    echo "创建故障后快照..."
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    CALL sp_create_snapshot('Storm-外部故障注入${i}-$(date +'%Y%m%d-%H%M%S')');
    " 2>/dev/null | tail -n +2
    
    # 间隔时间
    if [ $i -lt $FAULT_REPEAT ]; then
        echo "等待 ${FAULT_INTERVAL}s 进行下一次注入..."
        sleep $FAULT_INTERVAL
    fi
done

echo ""
echo "=========================================="
echo "  外部故障注入完成"
echo "=========================================="
EXPECTED_TIME=$((MESSAGE_COUNT / SPEED + FAULT_DELAY + FAULT_REPEAT * FAULT_INTERVAL + 20))
echo "故障日志: $LOG_FILE"
echo ""
echo "提示：可以在另一个终端执行以下命令查看进度："
echo "  - 查看 Storm UI: http://node1:8080"
echo "  - 查看数据库统计: mysql -h node1 -u exp_user -ppassword stream_experiment -e 'SELECT * FROM v_duplicate_stats;'"
echo ""
echo "后续操作："
echo "1. 等待数据处理完成（建议等待 $((EXPECTED_TIME * 2)) 秒）"
echo "2. 查看快照对比: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history ORDER BY snapshot_time DESC LIMIT 10;\""
echo "3. 停止测试: ./stop-all.sh"
