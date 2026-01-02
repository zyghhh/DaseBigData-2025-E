#!/bin/bash
# ========================================
# Flink At-Least-Once 外部故障测试脚本
# 在 Node 1 执行
# 对标: start-storm-external-fault-test.sh
# 故障类型: Kill TaskManager（自动重启）
# ========================================

echo "=== Flink At-Least-Once 外部故障测试 ==="

# 默认参数
MESSAGE_COUNT=${1:-100000}      # 消息总数（默认 10万）
SPEED=${2:-2000}                # 发送速率（默认 2000 msg/s）
FAULT_DELAY=${3:-30}            # 故障延迟时间（默认实验启动后 30 秒）
FAULT_REPEAT=${4:-3}            # 故障重复次数（默认 3 次）
FAULT_INTERVAL=${5:-30}         # 故障间隔时间（默认 30 秒）

echo "测试配置："
echo "  - 消息总数      : $MESSAGE_COUNT"
echo "  - 发送速率      : $SPEED msg/s"
echo "  - 故障延迟      : ${FAULT_DELAY}s（实验启动后等待时间）"
echo "  - 故障次数      : $FAULT_REPEAT 次"
echo "  - 故障间隔      : ${FAULT_INTERVAL}s"
echo "  - 故障类型      : Kill TaskManager（自动重启）"
echo ""

# 0. 复位数据库（仅清空 metrics，保留快照）
echo "[0/5] 复位数据库..."
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();" 2>/dev/null
echo "✓ 数据库已复位"

# 1. 启动数据生成器（固定数量模式）
echo "[1/5] 启动数据生成器（Node 2）- 固定 $MESSAGE_COUNT 条消息..."
ssh node2 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=DataGenerator -jar data-generator.jar source_data $SPEED $MESSAGE_COUNT > generator.log 2>&1 &" && sleep 1
echo "✓ 数据生成器已启动（将生成 $MESSAGE_COUNT 条消息后自动停止）"

# 2. 提交 Flink Job（正常无故障版本）
echo "[2/5] 提交 Flink Job（正常版本，无内部故障注入）..."
cd /opt/experiment

/opt/flink/bin/flink run -d \
  -c com.dase.bigdata.job.FlinkAtLeastOnceJob \
  experiment-job.jar

echo "✓ Flink Job 已提交"

# 3. 启动指标收集器（Node 3）
echo "[3/5] 启动指标收集器（Node 3）..."
ssh node3 "cd /opt/experiment && nohup java -Xmx512m -Dapp.name=MetricsCollector -jar metrics-collector.jar flink_sink flink-external-fault > collector-flink-external.log 2>&1 &" && sleep 1
echo "✓ 指标收集器已启动"

# 4. 创建故障前快照
echo "[4/5] 创建故障前快照..."
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_create_snapshot('Flink-外部故障前基线-$(date +'%Y%m%d-%H%M%S')');
" 2>/dev/null | tail -n +2

# 5. 等待后自动注入故障
echo "[5/5] 等待 ${FAULT_DELAY} 秒后开始注入故障..."
sleep $FAULT_DELAY

echo ""
echo "=========================================="
echo "  开始注入外部故障（Kill TaskManager）"
echo "=========================================="

LOG_FILE="/opt/experiment/fault-injection-log.csv"

for i in $(seq 1 $FAULT_REPEAT); do
    echo ""
    echo "======== 故障注入 #${i}/${FAULT_REPEAT} ========"
    INJECT_TIME=$(date +'%Y-%m-%d %H:%M:%S')
    
    # 查找 TaskManager 进程
    TM_PIDS=$(jps | grep TaskManagerRunner | awk '{print $1}')
    
    if [ -z "$TM_PIDS" ]; then
        echo "⚠ 警告: 未找到 TaskManager 进程"
    else
        # 随机选择一个 TM
        TM_PID=$(echo "$TM_PIDS" | shuf -n 1)
        echo "[${INJECT_TIME}] Target TaskManager PID: $TM_PID"
        
        # 记录故障
        echo "$INJECT_TIME,kill-tm,$TM_PID" >> "$LOG_FILE"
        
        # Kill 进程
        kill -9 $TM_PID
        echo "✓ TaskManager (PID: $TM_PID) 已被 Kill"
        
        # [Standalone 模式] 手动重启 TaskManager
        echo "正在重启 TaskManager..."
        sleep 3  # 等待进程完全退出
        
        # 在后台重启 TaskManager
        nohup /opt/flink/bin/taskmanager.sh start > /dev/null 2>&1 &
        
        # 等待 TaskManager 注册到 JobManager
        echo "等待 TaskManager 重新注册（约 10 秒）..."
        sleep 10
        
        # 验证是否重启成功
        NEW_TM_COUNT=$(jps | grep TaskManagerRunner | wc -l)
        if [ $NEW_TM_COUNT -gt 0 ]; then
            echo "✓ TaskManager 已成功重启"
        else
            echo "✗ TaskManager 重启失败，请检查日志"
        fi
    fi
    
    # 创建故障后快照
    echo "创建故障后快照..."
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    CALL sp_create_snapshot('Flink-外部故障注入${i}-$(date +'%Y%m%d-%H%M%S')');
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
echo "  - 查看 Flink UI: http://node1:8081"
echo "  - 查看数据库统计: mysql -h node1 -u exp_user -ppassword stream_experiment -e 'SELECT * FROM v_duplicate_stats;'"
echo ""
echo "后续操作："
echo "1. 等待数据处理完成（建议等待 $((EXPECTED_TIME * 2)) 秒）"
echo "2. 查看快照对比: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history ORDER BY snapshot_time DESC LIMIT 10;\""
echo "3. 停止测试: ./stop-all.sh"
