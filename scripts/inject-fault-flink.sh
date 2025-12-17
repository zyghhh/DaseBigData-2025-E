#!/bin/bash
# ========================================
# Flink 故障注入脚本
# 在 Node 1 执行
# 支持: Kill TaskManager、网络隔离、JobManager故障
# ========================================

FAULT_TYPE=${1:-help}
REPEAT_TIMES=${2:-1}
INTERVAL_SEC=${3:-30}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo "用法: ./inject-fault-flink.sh <fault_type> [repeat_times] [interval_sec]"
    echo ""
    echo "故障类型:"
    echo "  kill-tm       - Kill TaskManager 进程"
    echo "  kill-jm       - Kill JobManager 进程"
    echo "  network-tm    - 网络隔离 TaskManager (需要 iptables)"
    echo "  checkpoint    - 触发强制 Checkpoint"
    echo ""
    echo "参数:"
    echo "  repeat_times  - 重复注入次数(默认1)"
    echo "  interval_sec  - 每次注入间隔秒数(默认30)"
    echo ""
    echo "示例:"
    echo "  ./inject-fault-flink.sh kill-tm 3 30    # 每30秒Kill一次TM,共3次"
    echo "  ./inject-fault-flink.sh kill-jm 1       # Kill JM一次"
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
echo "间隔时间: ${INTERVAL_SEC}秒"
echo -e "${BLUE}=======================================${NC}"
echo ""

# 创建快照(故障前)
echo -e "${GREEN}[步骤0] 创建故障前快照...${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_create_snapshot('Flink-故障前基线-$(date +'%Y%m%d-%H%M%S')');
" 2>/dev/null | tail -n +2

for i in $(seq 1 $REPEAT_TIMES); do
    echo ""
    echo -e "${YELLOW}======== 注入 #${i}/${REPEAT_TIMES} ========${NC}"
    INJECT_TIME=$(date +'%Y-%m-%d %H:%M:%S')
    
    case $FAULT_TYPE in
        kill-tm)
            echo -e "${RED}[${INJECT_TIME}] Kill TaskManager...${NC}"
            
            # 定义 Worker 节点列表
            WORKER_NODES=("node2" "node3")
            
            # 收集所有节点的 TaskManager 信息
            declare -a TM_LIST
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
                
                # [Standalone 模式] 远程重启 TaskManager
                echo "检测到 Standalone 模式，正在 $TARGET_NODE 上重启 TaskManager..."
                sleep 3  # 等待进程完全退出
                
                # 远程重启 TaskManager
                ssh $TARGET_NODE "nohup /opt/flink/bin/taskmanager.sh start > /dev/null 2>&1 &"
                
                # 等待 TaskManager 注册到 JobManager
                echo "等待 TaskManager 重新注册（约 10 秒）..."
                sleep 10
                
                # 验证是否重启成功
                NEW_TM_COUNT=$(ssh $TARGET_NODE "jps | grep TaskManagerRunner | wc -l")
                if [ $NEW_TM_COUNT -gt 0 ]; then
                    echo -e "${GREEN}✓ $TARGET_NODE 上的 TaskManager 已成功重启${NC}"
                else
                    echo -e "${RED}✗ $TARGET_NODE 上的 TaskManager 重启失败，请检查日志${NC}"
                fi
                
                # 等待 Flink Job 恢复到 RUNNING 状态
                echo -e "${BLUE}等待 Flink Job 恢复正常...${NC}"
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
                
                echo -e "${YELLOW}警告: JobManager 故障后需要手动重启集群${NC}"
                echo "执行: /opt/flink/bin/start-cluster.sh"
            fi
            ;;
            
        network-tm)
            echo -e "${RED}[${INJECT_TIME}] 网络隔离 TaskManager...${NC}"
            
            # 获取 TaskManager 所在节点(假设在 node2)
            TARGET_NODE="node2"
            
            echo "在 $TARGET_NODE 上添加网络隔离规则..."
            ssh $TARGET_NODE "sudo iptables -A OUTPUT -p tcp --dport 6123 -j DROP"
            
            echo "$INJECT_TIME,network-tm,$TARGET_NODE" >> /opt/experiment/fault-injection-log.csv
            echo -e "${GREEN}✓ $TARGET_NODE 网络已隔离${NC}"
            
            # 等待一段时间后恢复
            echo "等待 ${INTERVAL_SEC}秒 后恢复网络..."
            sleep $INTERVAL_SEC
            
            ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp --dport 6123 -j DROP"
            echo -e "${GREEN}✓ 网络已恢复${NC}"
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
    
    # 验证系统状态后再创建快照
    echo -e "${BLUE}验证系统状态...${NC}"
    
    # 1. 检查 Job 状态
    RUNNING_JOBS=$(/opt/flink/bin/flink list 2>/dev/null | grep RUNNING | wc -l)
    if [ $RUNNING_JOBS -eq 0 ]; then
        echo -e "${RED}警告: 没有运行中的 Job，快照可能不准确${NC}"
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
    
    # 创建故障后快照
    echo -e "${GREEN}创建故障后快照...${NC}"
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    CALL sp_create_snapshot('Flink-故障注入${i}-${FAULT_TYPE}-$(date +'%Y%m%d-%H%M%S')');
    " 2>/dev/null | tail -n +2
    
    # 间隔时间
    if [ $i -lt $REPEAT_TIMES ]; then
        echo -e "${BLUE}等待 ${INTERVAL_SEC}秒 进行下一次注入...${NC}"
        sleep $INTERVAL_SEC
    fi
done

echo ""
echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}  故障注入完成${NC}"
echo -e "${GREEN}=======================================${NC}"
echo "故障日志: /opt/experiment/fault-injection-log.csv"
echo ""
echo "对比故障前后快照:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history ORDER BY snapshot_time DESC LIMIT 5;\""
