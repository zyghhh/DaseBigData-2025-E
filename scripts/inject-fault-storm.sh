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
DISTRIBUTION=${4:-fixed}  # fixed 或 poisson

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo "用法: ./inject-fault-storm.sh <fault_type> [repeat_times] [interval_sec] [distribution]"
    echo ""
    echo "故障类型:"
    echo "  kill-worker   - Kill Storm Worker 进程(随机挑选一个)"
    echo "  kill-nimbus   - Kill Nimbus 进程"
    echo "  network-worker- 网络隔离 Worker 所在节点(需要 iptables)"
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
    echo "  ./inject-fault-storm.sh kill-worker 3 30 fixed       # 每30秒Kill一次Worker"
    echo "  ./inject-fault-storm.sh kill-worker 5 20 poisson     # 平均每20秒Kill一次(泊松)"
    echo "  ./inject-fault-storm.sh network-worker 2 60 poisson  # 平均每60秒一次网络隔离"
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
            
            # 收集所有节点的 Worker 信息（每次循环重新收集）
            WORKER_LIST=()
            for node in "${WORKER_NODES[@]}"; do
                echo "正在查找 $node 上的 Storm Worker..."
                WORKER_PIDS=$(ssh $node "jps | grep -w Worker | awk '{print \$1}'" 2>/dev/null)
                
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
            NIMBUS_PID=$(jps | grep -w Nimbus | awk '{print $1}')
            if [ -z "$NIMBUS_PID" ]; then
                echo -e "${YELLOW}警告: 未找到 Nimbus 进程${NC}"
            else
                echo "Target Nimbus PID: $NIMBUS_PID"
                echo "$INJECT_TIME,kill-nimbus,$NIMBUS_PID" >> "$LOG_FILE"
                kill -9 $NIMBUS_PID
                echo -e "${GREEN}✓ Nimbus (PID: $NIMBUS_PID) 已被 Kill${NC}"
                
                # [模拟 YARN] 自动重启 Nimbus
                echo -e "${BLUE}模拟 YARN 重启 Nimbus...${NC}"
                echo "等待 8 秒（模拟Nimbus调度延迟）..."
                sleep 8
                
                # 清理残留进程
                REMAINING_NIMBUS=$(jps | grep -w Nimbus | awk '{print $1}')
                if [ -n "$REMAINING_NIMBUS" ]; then
                    echo "清理残留 Nimbus 进程: $REMAINING_NIMBUS"
                    kill -9 $REMAINING_NIMBUS 2>/dev/null
                    sleep 2
                fi
                
                # 重启 Nimbus
                echo "启动新的 Nimbus..."
                nohup /opt/storm/bin/storm nimbus > /opt/storm/logs/nimbus.out 2>&1 &
                
                # 等待 Nimbus 启动
                echo "等待 Nimbus 进程启动（约 10 秒）..."
                sleep 10
                
                # 验证重启
                NEW_NIMBUS_COUNT=$(jps | grep -w Nimbus | wc -l)
                if [ $NEW_NIMBUS_COUNT -gt 0 ]; then
                    echo -e "${GREEN}✓ Nimbus 已成功重启${NC}"
                else
                    echo -e "${RED}✗ Nimbus 重启失败${NC}"
                fi
                
                # 等待 Worker 重新连接
                echo "等待 Worker 重新连接到 Nimbus（约 15 秒）..."
                sleep 15
                
                # 总恢复时间
                RECOVERY_TIME=$((8 + 10 + 15))
                echo -e "${BLUE}Nimbus 恢复耗时: 约 ${RECOVERY_TIME} 秒${NC}"
            fi
            ;;

        network-worker)
            echo -e "${RED}[${INJECT_TIME}] 网络隔离 Worker 节点...${NC}"
            # 假设 Worker 主要运行在 node2 上, 如有需要可手动修改
            TARGET_NODE="node2"
            
            # 清理可能残留的旧规则
            echo "清理可能存在的旧规则..."
            ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp --dport 6627 -j DROP 2>/dev/null || true" 2>/dev/null
            ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp --dport 6627 -j DROP 2>/dev/null || true" 2>/dev/null
            
            # 验证隔离前的连通性
            echo "验证隔离前连通性..."
            BEFORE_TEST=$(ssh $TARGET_NODE "timeout 2 bash -c '</dev/tcp/node1/6627' 2>/dev/null && echo 'connected' || echo 'failed'")
            echo "  隔离前状态: $BEFORE_TEST"
            
            # 添加网络隔离规则
            echo "在 $TARGET_NODE 上添加网络隔离规则(阻断与 Nimbus 的通信)..."
            ssh $TARGET_NODE "sudo iptables -A OUTPUT -p tcp --dport 6627 -j DROP" 2>/dev/null
            
            # 验证隔离是否生效
            echo "验证网络隔离是否生效..."
            RULE_COUNT=$(ssh $TARGET_NODE "sudo iptables -L OUTPUT -n | grep -c '6627'" 2>/dev/null)
            if [ "$RULE_COUNT" -gt 0 ]; then
                echo -e "${GREEN}✓ iptables 规则已添加 (规则数: $RULE_COUNT)${NC}"
                if [ "$RULE_COUNT" -gt 1 ]; then
                    echo -e "${YELLOW}⚠ 警告: 检测到多条规则，可能存在残留${NC}"
                fi
                ssh $TARGET_NODE "sudo iptables -L OUTPUT -n -v | grep 6627" 2>/dev/null
            else
                echo -e "${RED}✗ iptables 规则添加失败${NC}"
            fi
            
            # 测试隔离后的连通性
            AFTER_TEST=$(ssh $TARGET_NODE "timeout 2 bash -c '</dev/tcp/node1/6627' 2>/dev/null && echo 'connected' || echo 'failed'")
            echo "  隔离后状态: $AFTER_TEST"
            
            if [ "$AFTER_TEST" = "failed" ]; then
                echo -e "${GREEN}✓ 网络隔离验证成功${NC}"
            else
                echo -e "${YELLOW}⚠ 警告: 网络可能未完全隔离${NC}"
            fi
            
            echo "$INJECT_TIME,network-worker,$TARGET_NODE" >> "$LOG_FILE"
            echo -e "${GREEN}✓ $TARGET_NODE 网络已隔离${NC}"
            echo "等待 ${INTERVAL_SEC}秒 后恢复网络..."
            sleep $INTERVAL_SEC
            
            # 恢复网络（循环删除所有相关规则）
            echo "恢复网络（清理所有隔离规则）..."
            for i in {1..5}; do
                REMAINING=$(ssh $TARGET_NODE "sudo iptables -L OUTPUT -n | grep -c '6627'" 2>/dev/null)
                if [ "$REMAINING" -eq 0 ]; then
                    break
                fi
                ssh $TARGET_NODE "sudo iptables -D OUTPUT -p tcp --dport 6627 -j DROP" 2>/dev/null
            done
            
            # 验证网络恢复
            RESTORE_TEST=$(ssh $TARGET_NODE "timeout 2 bash -c '</dev/tcp/node1/6627' 2>/dev/null && echo 'connected' || echo 'failed'")
            echo "  恢复后状态: $RESTORE_TEST"
            
            FINAL_RULES=$(ssh $TARGET_NODE "sudo iptables -L OUTPUT -n | grep -c '6627'" 2>/dev/null)
            if [ "$RESTORE_TEST" = "connected" ] && [ "$FINAL_RULES" -eq 0 ]; then
                echo -e "${GREEN}✓ 网络已恢复并验证成功（已清理 iptables 规则）${NC}"
            else
                echo -e "${YELLOW}⚠ 警告: 网络恢复可能失败${NC}"
                if [ "$FINAL_RULES" -gt 0 ]; then
                    echo -e "${YELLOW}  残留规则数: $FINAL_RULES，请手动执行:${NC}"
                    echo "  ssh $TARGET_NODE 'sudo iptables -F OUTPUT'"
                fi
            fi
            ;;

        *)
            echo -e "${RED}错误: 未知的故障类型 '$FAULT_TYPE'${NC}"
            show_help
            ;;
    esac
    
    # 验证系统状态
    echo -e "${BLUE}验证系统状态...${NC}"
    
    # 1. 检查 Worker 进程数量
    TOTAL_WORKERS=0
    for node in "node2" "node3"; do
        WORKER_COUNT=$(ssh $node "ps aux | grep storm | grep worker | grep -v grep | wc -l" 2>/dev/null)
        TOTAL_WORKERS=$((TOTAL_WORKERS + WORKER_COUNT))
    done
    
    if [ $TOTAL_WORKERS -eq 0 ]; then
        echo -e "${RED}警告: 没有运行中的 Worker${NC}"
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
    
    # 间隔时间(除 network-worker 已内部 sleep)
    if [ $i -lt $REPEAT_TIMES ] && [ "$FAULT_TYPE" != "network-worker" ]; then
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
echo -e "${GREEN}  Storm 故障注入完成${NC}"
echo -e "${GREEN}=======================================${NC}"
echo "故障日志: $LOG_FILE"
echo ""
echo "手动创建快照:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_create_snapshot('Storm-故障测试-手动快照');\""
echo ""
echo "查看快照历史:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history ORDER BY snapshot_time DESC LIMIT 10;\""