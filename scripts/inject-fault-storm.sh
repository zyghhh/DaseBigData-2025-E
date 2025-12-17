#!/bin/bash
# ========================================
# Storm 故障注入脚本（外部异常评估）
# 在 Node 1 执行
# 支持: Kill Worker、Kill Nimbus、网络隔离 Worker
# ========================================

# TODO  ⚠ 警告: 未找到 Storm Worker 进程
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
    echo "用法: ./inject-fault-storm.sh <fault_type> [repeat_times] [interval_sec]"
    echo ""
    echo "故障类型:"
    echo "  kill-worker   - Kill Storm Worker 进程(随机挑选一个)"
    echo "  kill-nimbus   - Kill Nimbus 进程"
    echo "  network-worker- 网络隔离 Worker 所在节点(需要 iptables)"
    echo ""
    echo "参数:"
    echo "  repeat_times  - 重复注入次数(默认1)"
    echo "  interval_sec  - 每次注入间隔秒数(默认30)"
    echo ""
    echo "示例:"
    echo "  ./inject-fault-storm.sh kill-worker 3 30      # 每30秒Kill一次Worker,共3次"
    echo "  ./inject-fault-storm.sh kill-nimbus 1         # Kill Nimbus 一次"
    echo "  ./inject-fault-storm.sh network-worker 2 60   # 两次网络隔离 Worker 节点"
    exit 0
}

if [ "$FAULT_TYPE" == "help" ]; then
    show_help
fi

echo -e "${BLUE}=======================================${NC}"
echo -e "${RED}  Storm 故障注入${NC}"
echo -e "${BLUE}=======================================${NC}"
echo "故障类型: $FAULT_TYPE"
echo "重复次数: $REPEAT_TIMES"
echo "间隔时间: ${INTERVAL_SEC}秒"
echo -e "${BLUE}=======================================${NC}"
echo ""

# 创建快照(故障前)
echo -e "${GREEN}[步骤0] 创建故障前快照...${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_create_snapshot('Storm-故障前基线-$(date +'%Y%m%d-%H%M%S')');
" 2>/dev/null | tail -n +2

LOG_FILE="/opt/experiment/fault-injection-storm-log.csv"

for i in $(seq 1 $REPEAT_TIMES); do
    echo ""
    echo -e "${YELLOW}======== 注入 #${i}/${REPEAT_TIMES} ========${NC}"
    INJECT_TIME=$(date +'%Y-%m-%d %H:%M:%S')
    
    case $FAULT_TYPE in
        kill-worker)
            echo -e "${RED}[${INJECT_TIME}] Kill Storm Worker...${NC}"
            
            # 定义 Worker 节点列表
            WORKER_NODES=("node2" "node3")
            
            # 收集所有节点的 Worker 信息
            declare -a WORKER_LIST
            for node in "${WORKER_NODES[@]}"; do
                echo "正在查找 $node 上的 Storm Worker..."
                WORKER_PIDS=$(ssh $node "ps aux | grep storm | grep worker | grep -v grep | awk '{print \$2}'" 2>/dev/null)
                
                if [ -n "$WORKER_PIDS" ]; then
                    for pid in $WORKER_PIDS; do
                        WORKER_LIST+=("$node:$pid")
                        echo "  发现: $node (PID: $pid)"
                    done
                fi
            done
            
            if [ ${#WORKER_LIST[@]} -eq 0 ]; then
                echo -e "${YELLOW}警告: 未在任何节点找到 Storm Worker 进程${NC}"
            else
                # 随机选择一个 Worker
                TARGET_INDEX=$((RANDOM % ${#WORKER_LIST[@]}))
                TARGET_INFO="${WORKER_LIST[$TARGET_INDEX]}"
                TARGET_NODE=$(echo $TARGET_INFO | cut -d':' -f1)
                TARGET_PID=$(echo $TARGET_INFO | cut -d':' -f2)
                
                echo ""
                echo -e "${YELLOW}目标节点: $TARGET_NODE${NC}"
                echo -e "${YELLOW}目标 PID: $TARGET_PID${NC}"
                
                # 记录故障
                echo "$INJECT_TIME,kill-worker,$TARGET_NODE,$TARGET_PID" >> "$LOG_FILE"
                
                # 远程 Kill 进程
                ssh $TARGET_NODE "kill -9 $TARGET_PID"
                echo -e "${GREEN}✓ Worker (Node: $TARGET_NODE, PID: $TARGET_PID) 已被 Kill${NC}"
                
                # 等待 Storm Nimbus 重新调度 Worker
                echo -e "${BLUE}等待 Storm 自动重新调度 Worker...${NC}"
                MAX_WAIT=60  # 最多等待60秒
                WAIT_COUNT=0
                
                while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
                    # 检查该节点上是否有新的 Worker 进程
                    NEW_WORKER_COUNT=$(ssh $TARGET_NODE "ps aux | grep storm | grep worker | grep -v grep | wc -l" 2>/dev/null)
                    
                    if [ $NEW_WORKER_COUNT -gt 0 ]; then
                        echo -e "${GREEN}✓ $TARGET_NODE 上的 Worker 已重新启动${NC}"
                        
                        # 额外等待10秒，确保任务分配完成
                        echo "等待任务分配完成（10秒）..."
                        sleep 10
                        break
                    else
                        echo -n "."
                        sleep 2
                        WAIT_COUNT=$((WAIT_COUNT + 2))
                    fi
                done
                
                if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
                    echo -e "${RED}✗ Worker 重启超时，请检查 Storm UI${NC}"
                    echo "当前 Worker 状态:"
                    for node in "${WORKER_NODES[@]}"; do
                        COUNT=$(ssh $node "ps aux | grep storm | grep worker | grep -v grep | wc -l" 2>/dev/null)
                        echo "  $node: $COUNT 个 Worker 进程"
                    done
                fi
            fi
            ;;

        kill-nimbus)
            echo -e "${RED}[${INJECT_TIME}] Kill Nimbus...${NC}"
            NIMBUS_PID=$(ps aux | grep 'storm nimbus' | grep -v grep | awk '{print $2}')
            if [ -z "$NIMBUS_PID" ]; then
                echo -e "${YELLOW}警告: 未找到 Nimbus 进程${NC}"
            else
                echo "Target Nimbus PID: $NIMBUS_PID"
                echo "$INJECT_TIME,kill-nimbus,$NIMBUS_PID" >> "$LOG_FILE"
                kill -9 $NIMBUS_PID
                echo -e "${GREEN}✓ Nimbus (PID: $NIMBUS_PID) 已被 Kill${NC}"
                echo -e "${YELLOW}提示: 需要手动重新启动 Nimbus 和 UI 进程${NC}"
                echo "例如: nohup /opt/storm/bin/storm nimbus > /opt/storm/logs/nimbus.out 2>&1 &"
            fi
            ;;

        network-worker)
            echo -e "${RED}[${INJECT_TIME}] 网络隔离 Worker 节点...${NC}"
            # 假设 Worker 主要运行在 node2 上, 如有需要可手动修改
            TARGET_NODE="node2"
            echo "在 $TARGET_NODE 上添加网络隔离规则(阻断与 Nimbus 的通信)..."
            ssh $TARGET_NODE "sudo iptables -A OUTPUT -p tcp --dport 6627 -j DROP" 2>/dev/null
            echo "$INJECT_TIME,network-worker,$TARGET_NODE" >> "$LOG_FILE"
            echo -e "${GREEN}✓ $TARGET_NODE 网络已隔离${NC}"
            echo "等待 ${INTERVAL_SEC}秒 后恢复网络..."
            sleep $INTERVAL_SEC
            ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp --dport 6627 -j DROP" 2>/dev/null
            echo -e "${GREEN}✓ 网络已恢复${NC}"
            ;;

        *)
            echo -e "${RED}错误: 未知的故障类型 '$FAULT_TYPE'${NC}"
            show_help
            ;;
    esac
    
    # 验证系统状态后再创建快照
    echo -e "${BLUE}验证系统状态...${NC}"
    
    # 1. 检查 Worker 进程数量
    TOTAL_WORKERS=0
    for node in "node2" "node3"; do
        WORKER_COUNT=$(ssh $node "ps aux | grep storm | grep worker | grep -v grep | wc -l" 2>/dev/null)
        TOTAL_WORKERS=$((TOTAL_WORKERS + WORKER_COUNT))
    done
    
    if [ $TOTAL_WORKERS -eq 0 ]; then
        echo -e "${RED}警告: 没有运行中的 Worker，快照可能不准确${NC}"
    else
        echo -e "${GREEN}✓ 检测到 $TOTAL_WORKERS 个 Worker 进程运行中${NC}"
    fi
    
    # 2. 检查 Metrics Collector 是否正在写入数据
    BEFORE_COUNT=$(mysql -h node1 -u exp_user -ppassword stream_experiment -se "SELECT COUNT(*) FROM metrics WHERE framework='Storm';" 2>/dev/null)
    sleep 3
    AFTER_COUNT=$(mysql -h node1 -u exp_user -ppassword stream_experiment -se "SELECT COUNT(*) FROM metrics WHERE framework='Storm';" 2>/dev/null)
    
    if [ $AFTER_COUNT -gt $BEFORE_COUNT ]; then
        NEW_MSGS=$((AFTER_COUNT - BEFORE_COUNT))
        echo -e "${GREEN}✓ 数据流正常，3秒新增 $NEW_MSGS 条消息${NC}"
    else
        echo -e "${YELLOW}警告: 数据流可能已停止，请检查 Metrics Collector${NC}"
    fi
    
    # 创建故障后快照
    echo -e "${GREEN}创建故障后快照...${NC}"
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    CALL sp_create_snapshot('Storm-故障注入${i}-${FAULT_TYPE}-$(date +'%Y%m%d-%H%M%S')');
    " 2>/dev/null | tail -n +2
    
    # 间隔时间(除 network-worker 已内部 sleep)
    if [ $i -lt $REPEAT_TIMES ] && [ "$FAULT_TYPE" != "network-worker" ]; then
        echo -e "${BLUE}等待 ${INTERVAL_SEC}秒 进行下一次注入...${NC}"
        sleep $INTERVAL_SEC
    fi
done

echo ""
echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}  Storm 故障注入完成${NC}"
echo -e "${GREEN}=======================================${NC}"
echo "故障日志: $LOG_FILE"
echo ""
echo "对比故障前后快照:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history ORDER BY snapshot_time DESC LIMIT 10;\""