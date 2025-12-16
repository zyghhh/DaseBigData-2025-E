#!/bin/bash
# ========================================
# 查看 Storm 异常测试结果（增强版）
# 在 Node 1 执行
# 支持快照创建、历史对比、详细分析
# ========================================

FAULT_TYPE=${1:-none}
CREATE_SNAPSHOT=${2:-no}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}Storm 异常测试结果分析 ($FAULT_TYPE)${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# 1. 查看延迟统计（含百分位）
echo -e "${YELLOW}📊 延迟统计（含P50/P95/P99）：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_latency_percentiles WHERE 任务类型 LIKE 'storm%';
" 2>/dev/null

echo ""

# 2. 查看重复率统计
echo -e "${YELLOW}🔄 重复率统计：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_duplicate_stats WHERE 任务类型 LIKE 'storm%';
" 2>/dev/null

echo ""

# 3. 查看综合对比
echo -e "${YELLOW}📈 综合对比：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_comparison WHERE 任务类型 LIKE 'storm%';
" 2>/dev/null

echo ""

# 4. 吞吐量统计
echo -e "${YELLOW}⚡ 吞吐量统计（最近10秒）：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_throughput_per_second 
WHERE 任务类型 LIKE 'storm%' 
ORDER BY 时间点 DESC LIMIT 10;
" 2>/dev/null

echo ""

# 5. 重复消息详情
echo -e "${YELLOW}📋 重复消息详情（Top 20）：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_get_duplicates('storm');
" 2>/dev/null

echo ""

# 6. 延迟分布
echo -e "${YELLOW}📊 延迟分布区间：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_get_latency_distribution('storm');
" 2>/dev/null

echo ""

# 7. 理论分析
echo -e "${YELLOW}🧮 理论分析：${NC}"
case $FAULT_TYPE in
  none)
    echo "  - 异常类型: 无异常"
    echo "  - 预期重复: 0"
    echo "  - 预期恢复时间: N/A"
    ;;
  spout)
    echo "  - 异常类型: Spout 异常"
    echo "  - 理论重复数 ≈ spout.max.pending × 异常次数"
    echo "  - 预期恢复时间: Kafka rebalance时间 (< 30s)"
    ;;
  bolt-before)
    echo "  - 异常类型: Bolt emit 之前异常"
    echo "  - 理论重复数: 0（消息不会被 emit）"
    echo "  - 预期恢复时间: < 10s"
    ;;
  bolt-after)
    echo "  - 异常类型: Bolt emit 之后异常"
    echo "  - 理论重复数 = 异常次数（下游会重复处理）"
    echo "  - 预期恢复时间: < 10s"
    ;;
  acker)
    echo "  - 异常类型: Acker 异常（需要手动 Kill）"
    echo "  - 理论重复数 ≈ spout.max.pending × Kill 次数"
    echo "  - 预期恢复时间: message.timeout (60s)"
    ;;
esac

echo ""
echo -e "${BLUE}=========================================${NC}"

# 8. 快照管理
if [ "$CREATE_SNAPSHOT" = "yes" ] || [ "$CREATE_SNAPSHOT" = "y" ]; then
    echo -e "${GREEN}📸 创建统计快照...${NC}"
    SNAPSHOT_NOTE="Storm异常测试-$FAULT_TYPE-$(date +'%Y%m%d-%H%M%S')"
    mysql -h node1 -u exp_user -ppassword stream_experiment -e "
    CALL sp_create_snapshot('$SNAPSHOT_NOTE');
    " 2>/dev/null
    echo -e "${GREEN}✓ 快照已创建${NC}"
    echo ""
else
    echo -e "${YELLOW}💡 提示: 添加参数 'yes' 可自动创建快照${NC}"
    echo -e "${YELLOW}   示例: $0 $FAULT_TYPE yes${NC}"
    echo ""
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}✓ 结果分析完成${NC}"
echo -e "${BLUE}=========================================${NC}"
