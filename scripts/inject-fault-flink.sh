#!/bin/bash
# ========================================
# Flink 故障注入脚本
# 在 Node 1 执行
# 支持: Kill TaskManager、网络隔离、JobManager故障
# ========================================

FAULT_TYPE=${1:-help}
REPEAT_TIMES=${2:-1}
INTERVAL_SEC=${3:-30}
DISTRIBUTION=${4:-fixed}  # fixed 或 poisson

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo "用法: ./inject-fault-flink.sh <fault_type> [repeat_times] [interval_sec] [distribution]"
    echo ""
    echo "故障类型:"
    echo "  kill-tm       - Kill TaskManager 进程"
    echo "  kill-jm       - Kill JobManager 进程"
    echo "  network-tm    - 网络隔离 TaskManager (需要 iptables)"
    echo "  checkpoint    - 触发强制 Checkpoint"
    echo ""
    echo "参数:"
    echo "  repeat_times  - 重复注入次数(默认1)"
    echo "  interval_sec  - 间隔秒数(默认30)"
    echo "                  fixed模式: 固定间隔"
    echo "                  poisson模式: Lambda参数(平均间隔)"
    echo "  distribution  - 时间分布(默认fixed)"
    echo "                  fixed: 固定时间间隔"
    echo "                  poisson: 泊松分布(指数间隔)"
    echo ""
    echo "示例:"
    echo "  ./inject-fault-flink.sh kill-tm 3 30 fixed      # 每30秒Kill一次TM"
    echo "  ./inject-fault-flink.sh kill-tm 5 20 poisson    # 平均每20秒Kill一次(泊松)"
    echo "  ./inject-fault-flink.sh network-tm 3 45 poisson # 平均每45秒一次网络隔离"
    exit 0
}

if [ "$FAULT_TYPE" == "help" ]; then
    show_help
fi

echo -e "${BLUE}=======================================${NC}"
echo -e "${RED}  Flink 故障注入${NC}"
echo -e "${BLUE}=======================================${NC}"
echo "故障类型: $FAULT_TYPE"
echo "重复次数: $REPEAT_TIMES"
if [ "$DISTRIBUTION" = "poisson" ]; then
    echo "时间分布: 泊松分布(指数间隔)"
    echo "Lambda参数: ${INTERVAL_SEC}秒 (平均间隔)"
else
    echo "时间分布: 固定间隔"
    echo "间隔时间: ${INTERVAL_SEC}秒"
fi
echo -e "${BLUE}=======================================${NC}"
echo ""

# 泊松分布随机间隔生成函数
generate_poisson_interval() {
    local lambda=$1
    # 生成指数分布的随机间隔: X = -lambda * ln(U), U ~ Uniform(0,1)
    # 使用 awk 生成随机数并计算
    awk -v lambda="$lambda" 'BEGIN {
        srand();
        u = rand();
        if (u == 0) u = 0.001;  # 避免 ln(0)
        interval = -lambda * log(u);
        if (interval < 1) interval = 1;  # 最小间隔1秒
        printf "%.0f\n", interval;
    }'
}

for i in $(seq 1 $REPEAT_TIMES); do
    echo ""
    echo -e "${YELLOW}======== 注入 #${i}/${REPEAT_TIMES} ========${NC}"
    INJECT_TIME=$(date +'%Y-%m-%d %H:%M:%S')
    
    case $FAULT_TYPE in
        kill-tm)
            echo -e "${RED}[${INJECT_TIME}] Kill TaskManager...${NC}"
            
            # 定义 Worker 节点列表
            WORKER_NODES=("node2" "node3")
            
            # 收集所有节点的 TaskManager 信息（每次循环重新收集）
            TM_LIST=()
            for node in "${WORKER_NODES[@]}"; do
                echo "正在查找 $node 上的 TaskManager..."
                TM_PIDS=$(ssh $node "jps | grep TaskManagerRunner | awk '{print \$1}'" 2>/dev/null)
                
                if [ -n "$TM_PIDS" ]; then
                    for pid in $TM_PIDS; do
                        TM_LIST+=("$node:$pid")
                        echo "  发现: $node (PID: $pid)"
                    done
                fi
            done
            
            if [ ${#TM_LIST[@]} -eq 0 ]; then
                echo -e "${YELLOW}警告: 未在任何节点找到 TaskManager 进程${NC}"
            else
                # 随机选择一个 TM
                TARGET_INDEX=$((RANDOM % ${#TM_LIST[@]}))
                TARGET_INFO="${TM_LIST[$TARGET_INDEX]}"
                TARGET_NODE=$(echo $TARGET_INFO | cut -d':' -f1)
                TM_PID=$(echo $TARGET_INFO | cut -d':' -f2)
                
                echo ""
                echo -e "${YELLOW}目标节点: $TARGET_NODE${NC}"
                echo -e "${YELLOW}目标 PID: $TM_PID${NC}"
                
                # 记录故障
                echo "$INJECT_TIME,kill-tm,$TARGET_NODE,$TM_PID" >> /opt/experiment/fault-injection-log.csv
                
                # 远程 Kill 进程
                ssh $TARGET_NODE "kill -9 $TM_PID"
                echo -e "${GREEN}✓ TaskManager (Node: $TARGET_NODE, PID: $TM_PID) 已被 Kill${NC}"
                
                # [Standalone 模式] 模拟 YARN 模式的重启延迟
                echo "检测到 Standalone 模式，模拟 YARN 重启延迟..."
                echo "等待 5 秒（模拟容器调度延迟）..."
                sleep 5
                
                # 清理所有可能残留的 TaskManager 进程
                echo "清理 $TARGET_NODE 上所有 TaskManager 进程..."
                REMAINING_TM=$(ssh $TARGET_NODE "jps | grep TaskManagerRunner | awk '{print \$1}'" 2>/dev/null)
                if [ -n "$REMAINING_TM" ]; then
                    for pid in $REMAINING_TM; do
                        echo "  清理残留进程: $pid"
                        ssh $TARGET_NODE "kill -9 $pid" 2>/dev/null
                    done
                    sleep 2
                fi
                
                # 远程重启 TaskManager（确保只启动一个）
                echo "启动新的 TaskManager..."
                ssh $TARGET_NODE "nohup /opt/flink/bin/taskmanager.sh start > /dev/null 2>&1 &"
                
                # 等待 TaskManager 进程启动（模拟容器启动时间）
                echo "等待 TaskManager 进程启动（约 8 秒）..."
                sleep 8
                
                # 验证是否重启成功
                NEW_TM_COUNT=$(ssh $TARGET_NODE "jps | grep TaskManagerRunner | wc -l")
                if [ $NEW_TM_COUNT -gt 0 ]; then
                    echo -e "${GREEN}✓ $TARGET_NODE 上的 TaskManager 已成功重启${NC}"
                else
                    echo -e "${RED}✗ $TARGET_NODE 上的 TaskManager 重启失败，请检查日志${NC}"
                fi
                
                # 等待 TaskManager 注册到 JobManager（模拟心跳建立）
                echo "等待 TaskManager 注册到 JobManager（约 10 秒）..."
                sleep 10
                
                # 等待 Flink Job 恢复到 RUNNING 状态（模拟 Checkpoint 恢复）
                echo -e "${BLUE}等待 Flink Job 从 Checkpoint 恢复...${NC}"
                MAX_WAIT=60  # 最多等待60秒
                WAIT_COUNT=0
                
                while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
                    JOB_STATE=$(/opt/flink/bin/flink list 2>/dev/null | grep -E 'RUNNING' | wc -l)
                    
                    if [ $JOB_STATE -gt 0 ]; then
                        echo -e "${GREEN}✓ Flink Job 已恢复到 RUNNING 状态${NC}"
                        
                        # 额外等待10秒，确保数据流稳定
                        echo "等待数据流稳定（10秒）..."
                        sleep 10
                        break
                    else
                        echo -n "."
                        sleep 2
                        WAIT_COUNT=$((WAIT_COUNT + 2))
                    fi
                done
                
                if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
                    echo -e "${RED}✗ Job 恢复超时，请检查 Flink WebUI${NC}"
                    echo "当前 Job 状态:"
                    /opt/flink/bin/flink list 2>/dev/null
                fi
                
                # 总恢复时间统计
                RECOVERY_TIME=$((5 + 8 + 10 + 10))  # 约 33 秒（不含 Job 恢复等待）
                echo -e "${BLUE}总恢复耗时: 约 ${RECOVERY_TIME}+ 秒${NC}"
            fi
            ;;
            
        kill-jm)
            echo -e "${RED}[${INJECT_TIME}] Kill JobManager...${NC}"
            
            JM_PID=$(jps | grep StandaloneSessionClusterEntrypoint | awk '{print $1}')
            
            if [ -z "$JM_PID" ]; then
                echo -e "${YELLOW}警告: 未找到 JobManager 进程${NC}"
            else
                echo "Target PID: $JM_PID"
                echo "$INJECT_TIME,kill-jm,$JM_PID" >> /opt/experiment/fault-injection-log.csv
                
                kill -9 $JM_PID
                echo -e "${GREEN}✓ JobManager (PID: $JM_PID) 已被 Kill${NC}"
                
                # [模拟 YARN] 自动重启 JobManager
                echo -e "${BLUE}检测到 Standalone 模式，模拟 YARN 重启 JobManager...${NC}"
                echo "等待 8 秒（模拟主节点容器调度延迟）..."
                sleep 8
                
                # 清理所有可能残留的 JobManager 进程
                echo "清理所有 JobManager 进程..."
                REMAINING_JM=$(jps | grep StandaloneSessionClusterEntrypoint | awk '{print $1}')
                if [ -n "$REMAINING_JM" ]; then
                    for pid in $REMAINING_JM; do
                        echo "  清理残留进程: $pid"
                        kill -9 $pid 2>/dev/null
                    done
                    sleep 2
                fi
                
                # 重启 JobManager
                echo "启动新的 JobManager..."
                nohup /opt/flink/bin/jobmanager.sh start > /dev/null 2>&1 &
                
                # 等待 JobManager 进程启动（模拟容器启动时间）
                echo "等待 JobManager 进程启动（约 10 秒）..."
                sleep 10
                
                # 验证是否重启成功
                NEW_JM_COUNT=$(jps | grep StandaloneSessionClusterEntrypoint | wc -l)
                if [ $NEW_JM_COUNT -gt 0 ]; then
                    echo -e "${GREEN}✓ JobManager 已成功重启${NC}"
                else
                    echo -e "${RED}✗ JobManager 重启失败，请检查日志${NC}"
                fi
                
                # 等待 TaskManager 重新注册（模拟心跳建立）
                echo "等待 TaskManager 重新连接到 JobManager（约 15 秒）..."
                sleep 15
                
                # 等待 Job 恢复（自动重新提交，模拟 YARN 模式）
                echo -e "${BLUE}模拟 YARN 模式自动重新提交 Job...${NC}"
                echo "等待 5 秒后重新提交 Job..."
                sleep 5
                
                # 重新提交 Job
                echo "正在提交 Job..."
                /opt/flink/bin/flink run -d \
                    -c com.dase.bigdata.job.FlinkAtLeastOnceJob \
                    /opt/experiment/experiment-job.jar \
                    > /tmp/flink-resubmit.log 2>&1
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ Job 已成功重新提交${NC}"
                    # 显示新的 Job ID
                    NEW_JOB_ID=$(cat /tmp/flink-resubmit.log | grep -oP 'JobID [a-f0-9]{32}' | awk '{print $2}')
                    if [ -n "$NEW_JOB_ID" ]; then
                        echo "新 Job ID: $NEW_JOB_ID"
                    fi
                else
                    echo -e "${RED}✗ Job 重新提交失败，请检查日志: /tmp/flink-resubmit.log${NC}"
                    cat /tmp/flink-resubmit.log
                fi
                

                
                # 总恢复时间统计
                RECOVERY_TIME=$((8 + 10 + 15 + 5 ))  # 约38秒
                echo -e "${BLUE}JobManager 恢复耗时: 约 ${RECOVERY_TIME} 秒${NC}"
            fi
            ;;
            
        network-tm)
            echo -e "${RED}[${INJECT_TIME}] 网络隔离 TaskManager...${NC}"
            
            # 获取 TaskManager 所在节点(假设在 node2)
            TARGET_NODE="node2"
            JM_NODE="node1"  # JobManager 节点
            
            # Flink 端口范围（RPC: 6121-6130）
            FLINK_PORTS=(6121 6122 6123 6124 6125 6126 6127 6128 6129 6130)
            
            # 清理可能残留的旧规则（必须完全匹配添加时的参数）
            echo "清理可能存在的旧规则..."
            for port in "${FLINK_PORTS[@]}"; do
                ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp -d $JM_NODE --dport $port -j REJECT --reject-with tcp-reset 2>/dev/null || true" 2>/dev/null
                ssh $TARGET_NODE "sudo iptables -D INPUT -p tcp -s $JM_NODE --sport $port -j REJECT --reject-with tcp-reset 2>/dev/null || true" 2>/dev/null
            done
            
            # 验证隔离前的连通性
            echo "验证隔离前连通性..."
            BEFORE_TEST=$(ssh $TARGET_NODE "timeout 2 bash -c '</dev/tcp/$JM_NODE/6123' 2>/dev/null && echo 'connected' || echo 'failed'")
            echo "  隔离前状态: $BEFORE_TEST"
            
            # 添加网络隔离规则（阻断 Flink 所有端口，使用 REJECT 立即断开）
            echo "在 $TARGET_NODE 上添加网络隔离规则(阻断 Flink 端口 6121-6130 与 $JM_NODE 的通信)..."
            for port in "${FLINK_PORTS[@]}"; do
                # OUTPUT: 阻断发往 JobManager 的连接
                ssh $TARGET_NODE "sudo iptables -A OUTPUT -p tcp -d $JM_NODE --dport $port -j REJECT --reject-with tcp-reset" 2>/dev/null
                # INPUT: 阻断来自 JobManager 的连接
                ssh $TARGET_NODE "sudo iptables -A INPUT -p tcp -s $JM_NODE --sport $port -j REJECT --reject-with tcp-reset" 2>/dev/null
            done
            
            # 验证隔离是否生效
            echo "验证网络隔离是否生效..."
            OUTPUT_RULES=$(ssh $TARGET_NODE "sudo iptables -L OUTPUT -n | grep -E '6(12[0-9]|130)' | wc -l" 2>/dev/null)
            INPUT_RULES=$(ssh $TARGET_NODE "sudo iptables -L INPUT -n | grep -E '6(12[0-9]|130)' | wc -l" 2>/dev/null)
            
            if [ "$OUTPUT_RULES" -ge ${#FLINK_PORTS[@]} ] && [ "$INPUT_RULES" -ge ${#FLINK_PORTS[@]} ]; then
                echo -e "${GREEN}✓ iptables 规则已添加 (OUTPUT: $OUTPUT_RULES, INPUT: $INPUT_RULES)${NC}"
                echo "OUTPUT 规则（前3条）:"
                ssh $TARGET_NODE "sudo iptables -L OUTPUT -n -v | grep -E '6(12[0-9]|130)' | head -3" 2>/dev/null
                echo "INPUT 规则（前3条）:"
                ssh $TARGET_NODE "sudo iptables -L INPUT -n -v | grep -E '6(12[0-9]|130)' | head -3" 2>/dev/null
            else
                echo -e "${RED}✗ iptables 规则添加不完整 (OUTPUT: $OUTPUT_RULES, INPUT: $INPUT_RULES, 预期各 ${#FLINK_PORTS[@]})${NC}"
            fi
            
            # 测试隔离后的连通性
            sleep 2  # 等待规则生效
            AFTER_TEST=$(ssh $TARGET_NODE "timeout 2 bash -c '</dev/tcp/$JM_NODE/6123' 2>/dev/null && echo 'connected' || echo 'failed'")
            echo "  隔离后状态: $AFTER_TEST"
            
            if [ "$AFTER_TEST" = "failed" ]; then
                echo -e "${GREEN}✓ 网络隔离验证成功${NC}"
            else
                echo -e "${YELLOW}⚠ 警告: 网络可能未完全隔离${NC}"
            fi
            
            # 检查 TaskManager 是否失去 Slot
            echo "检查 Flink 集群状态..."
            INITIAL_SLOTS=$(curl -s http://node1:8081/overview 2>/dev/null | grep -oP '"slots-available":\K[0-9]+')
            echo "  隔离前可用 Slots: $INITIAL_SLOTS"
            
            echo "$INJECT_TIME,network-tm,$TARGET_NODE" >> /opt/experiment/fault-injection-log.csv
            echo -e "${GREEN}✓ $TARGET_NODE 网络已隔离${NC}"
            echo "等待 ${INTERVAL_SEC}秒 后恢复网络..."
            
            # 每10秒检查一次 Slot 状态
            for ((t=0; t<INTERVAL_SEC; t+=10)); do
                sleep 10
                CURRENT_SLOTS=$(curl -s http://node1:8081/overview 2>/dev/null | grep -oP '"slots-available":\K[0-9]+')
                echo "  [${t}s] 当前可用 Slots: $CURRENT_SLOTS"
            done
            
            # 恢复网络（删除所有 Flink 端口的隔离规则）
            echo "恢复网络（清理所有隔离规则）..."
            for port in "${FLINK_PORTS[@]}"; do
                ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp -d $JM_NODE --dport $port -j REJECT --reject-with tcp-reset 2>/dev/null || true" 2>/dev/null
                ssh $TARGET_NODE "sudo iptables -D INPUT -p tcp -s $JM_NODE --sport $port -j REJECT --reject-with tcp-reset 2>/dev/null || true" 2>/dev/null
            done
            
            # 验证网络恢复
            sleep 2  # 等待规则清理完成
            RESTORE_TEST=$(ssh $TARGET_NODE "timeout 2 bash -c '</dev/tcp/$JM_NODE/6123' 2>/dev/null && echo 'connected' || echo 'failed'")
            echo "  恢复后状态: $RESTORE_TEST"
            
            OUTPUT_REMAIN=$(ssh $TARGET_NODE "sudo iptables -L OUTPUT -n | grep -E '6(12[0-9]|130)' | wc -l" 2>/dev/null)
            INPUT_REMAIN=$(ssh $TARGET_NODE "sudo iptables -L INPUT -n | grep -E '6(12[0-9]|130)' | wc -l" 2>/dev/null)
            
            if [ "$RESTORE_TEST" = "connected" ] && [ "$OUTPUT_REMAIN" -eq 0 ] && [ "$INPUT_REMAIN" -eq 0 ]; then
                echo -e "${GREEN}✓ 网络已恢复并验证成功（已清理 iptables 规则）${NC}"
                
                # 等待 TaskManager 自动恢复（Standalone 模式需手动处理）
                echo "等待 TaskManager 恢复连接..."
                sleep 15
                
                FINAL_SLOTS=$(curl -s http://node1:8081/overview 2>/dev/null | grep -oP '"slots-available":\K[0-9]+')
                echo "  恢复后可用 Slots: $FINAL_SLOTS"
                
                if [ "$FINAL_SLOTS" -eq 0 ] || [ -z "$FINAL_SLOTS" ]; then
                    echo -e "${YELLOW}⚠ Slots 未恢复，Standalone 模式可能需要手动重启 TaskManager${NC}"
                    echo "  手动重启命令: ssh $TARGET_NODE '/opt/flink/bin/taskmanager.sh restart'"
                fi
            else
                echo -e "${YELLOW}⚠ 警告: 网络恢复可能失败${NC}"
                if [ "$OUTPUT_REMAIN" -gt 0 ] || [ "$INPUT_REMAIN" -gt 0 ]; then
                    echo -e "${YELLOW}  残留规则 (OUTPUT: $OUTPUT_REMAIN, INPUT: $INPUT_REMAIN)，请手动清理:${NC}"
                    echo "  ssh $TARGET_NODE 'sudo iptables -F OUTPUT; sudo iptables -F INPUT'"
                fi
            fi
            ;;
            
        checkpoint)
            echo -e "${BLUE}[${INJECT_TIME}] 触发强制 Checkpoint...${NC}"
            
            # 获取 Job ID
            JOB_ID=$(/opt/flink/bin/flink list 2>/dev/null | grep RUNNING | awk '{print $4}' | head -n 1)
            
            if [ -z "$JOB_ID" ]; then
                echo -e "${YELLOW}警告: 未找到运行中的 Flink Job${NC}"
            else
                echo "Job ID: $JOB_ID"
                
                # 通过 REST API 触发 Checkpoint
                curl -X POST "http://localhost:8081/jobs/$JOB_ID/checkpoints" \
                     -H "Content-Type: application/json" 2>/dev/null
                
                echo "$INJECT_TIME,checkpoint,$JOB_ID" >> /opt/experiment/fault-injection-log.csv
                echo -e "${GREEN}✓ Checkpoint 已触发${NC}"
            fi
            ;;
            
        *)
            echo -e "${RED}错误: 未知的故障类型 '$FAULT_TYPE'${NC}"
            show_help
            ;;
    esac
    
    # 验证系统状态
    echo -e "${BLUE}验证系统状态...${NC}"
    
    # 1. 检查 Job 状态
    RUNNING_JOBS=$(/opt/flink/bin/flink list 2>/dev/null | grep RUNNING | wc -l)
    if [ $RUNNING_JOBS -eq 0 ]; then
        echo -e "${RED}警告: 没有运行中的 Job${NC}"
    else
        echo -e "${GREEN}✓ 检测到 $RUNNING_JOBS 个运行中的 Job${NC}"
    fi
    
    # 2. 检查 Metrics Collector 是否正在写入数据
    BEFORE_COUNT=$(mysql -h node1 -u exp_user -ppassword stream_experiment -se "SELECT COUNT(*) FROM metrics WHERE framework='Flink';" 2>/dev/null)
    sleep 3
    AFTER_COUNT=$(mysql -h node1 -u exp_user -ppassword stream_experiment -se "SELECT COUNT(*) FROM metrics WHERE framework='Flink';" 2>/dev/null)
    
    if [ $AFTER_COUNT -gt $BEFORE_COUNT ]; then
        NEW_MSGS=$((AFTER_COUNT - BEFORE_COUNT))
        echo -e "${GREEN}✓ 数据流正常，3秒新增 $NEW_MSGS 条消息${NC}"
    else
        echo -e "${YELLOW}警告: 数据流可能已停止，请检查 Metrics Collector${NC}"
    fi
    
    # 间隔时间(除 network-tm 已内部 sleep)
    if [ $i -lt $REPEAT_TIMES ] && [ "$FAULT_TYPE" != "network-tm" ]; then
        if [ "$DISTRIBUTION" = "poisson" ]; then
            # 泊松分布: 生成随机间隔
            ACTUAL_INTERVAL=$(generate_poisson_interval $INTERVAL_SEC)
            echo -e "${BLUE}等待 ${ACTUAL_INTERVAL}秒 进行下一次注入 (泊松分布)...${NC}"
            sleep $ACTUAL_INTERVAL
        else
            # 固定间隔
            echo -e "${BLUE}等待 ${INTERVAL_SEC}秒 进行下一次注入...${NC}"
            sleep $INTERVAL_SEC
        fi
    fi
done

echo ""
echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}  故障注入完成${NC}"
echo -e "${GREEN}=======================================${NC}"
echo "故障日志: /opt/experiment/fault-injection-log.csv"
echo ""
echo "手动创建快照:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_create_snapshot('Flink-故障测试-手动快照');\""
echo ""
echo "查看快照历史:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history ORDER BY snapshot_time DESC LIMIT 5;\""
