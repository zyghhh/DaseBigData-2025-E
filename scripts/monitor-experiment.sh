#!/bin/bash
# ========================================
# 实验实时监控与定时快照脚本
# 在 Node 1 执行
# 用法: ./monitor-experiment.sh <job_type> <window_seconds> <total_duration>
# 示例: ./monitor-experiment.sh flink 60 600  (每60秒创建快照,总共监控10分钟)
# ========================================

JOB_TYPE=${1:-flink}
WINDOW_SEC=${2:-60}       # 快照间隔(秒)
TOTAL_DURATION=${3:-600}  # 总监控时长(秒)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}  实验实时监控${NC}"
echo -e "${BLUE}=======================================${NC}"
echo "任务类型: $JOB_TYPE"
echo "快照间隔: ${WINDOW_SEC}秒"
echo "监控时长: ${TOTAL_DURATION}秒"
echo "预计快照数: $((TOTAL_DURATION / WINDOW_SEC))"
echo -e "${BLUE}=======================================${NC}"
echo ""

# 计算结束时间
END_TIME=$(($(date +%s) + TOTAL_DURATION))
SNAPSHOT_COUNT=0

# 循环监控
while [ $(date +%s) -lt $END_TIME ]; do
    SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))
    CURRENT_TIME=$(date +'%H:%M:%S')
    
    echo -e "${YELLOW}[${CURRENT_TIME}] 快照 #${SNAPSHOT_COUNT}${NC}"
    
    # 创建快照
    SNAP_NOTE="${JOB_TYPE}-实时监控-窗口${SNAPSHOT_COUNT}-$(date +'%Y%m%d-%H%M%S')"
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    CALL sp_create_snapshot('$SNAP_NOTE');
    " 2>/dev/null | tail -n +2
    
    # 显示当前统计
    echo -e "${GREEN}当前统计:${NC}"
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    SELECT 
        COUNT(*) AS 消息数,
        ROUND(AVG(latency), 2) AS 平均延迟_ms,
        COUNT(DISTINCT CASE WHEN process_count > 1 THEN msg_id END) AS 重复数
    FROM metrics 
    WHERE job_type='$JOB_TYPE';
    " 2>/dev/null
    
    echo ""
    
    # 等待下一个窗口
    REMAINING=$((END_TIME - $(date +%s)))
    if [ $REMAINING -gt $WINDOW_SEC ]; then
        echo -e "${BLUE}等待 ${WINDOW_SEC}秒 进入下一窗口...${NC}"
        sleep $WINDOW_SEC
    else
        echo -e "${GREEN}监控即将结束，剩余 ${REMAINING}秒${NC}"
        sleep $REMAINING
        break
    fi
done

echo ""
echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}  监控完成${NC}"
echo -e "${GREEN}=======================================${NC}"
echo "总快照数: $SNAPSHOT_COUNT"
echo ""
echo "查看所有快照:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"SELECT * FROM v_snapshot_history WHERE 备注 LIKE '%${JOB_TYPE}-实时监控%';\""
echo ""
echo "分析窗口趋势:"
echo "  mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_get_avg_stats('$JOB_TYPE', $SNAPSHOT_COUNT);\""
