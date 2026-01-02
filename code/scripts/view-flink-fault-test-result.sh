#!/bin/bash
# ========================================
# 查看 Flink 异常测试结果（对标 Storm 版本）
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
echo -e "${BLUE}Flink 异常测试结果分析 ($FAULT_TYPE)${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# 1. 查看延迟统计（含百分位）
echo -e "${YELLOW}📊 延迟统计（含P50/P95/P99）：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_latency_percentiles WHERE 任务类型 LIKE 'flink%';
" 2>/dev/null

echo ""

# 2. 查看重复率统计
echo -e "${YELLOW}🔄 重复率统计：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_duplicate_stats WHERE 任务类型 LIKE 'flink%';
" 2>/dev/null

echo ""

# 3. 查看综合对比
echo -e "${YELLOW}📈 综合对比：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_comparison WHERE 任务类型 LIKE 'flink%';
" 2>/dev/null

echo ""

# 4. 吞吐量统计
echo -e "${YELLOW}⚡ 吞吐量统计（最近10秒）：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_throughput_per_second 
WHERE 任务类型 LIKE 'flink%' 
ORDER BY 时间点 DESC LIMIT 10;
" 2>/dev/null

echo ""

# 5. 重复消息详情
echo -e "${YELLOW}📋 重复消息详情（Top 20）：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_get_duplicates('flink');
" 2>/dev/null

echo ""

# 6. 延迟分布
echo -e "${YELLOW}📊 延迟分布区间：${NC}"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
CALL sp_get_latency_distribution('flink');
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
  before)
    echo "  - 异常类型: Map 算子业务逻辑前抛异常"
    echo "  - 行为: 当前记录在业务逻辑前失败，由 Flink 重启后从上次 Checkpoint 位置重放"
    echo "  - 理论重复: 主要由 Checkpoint 对齐和重启次数决定，一般重复量有限"
    echo "  - 预期恢复时间: 受重启策略影响，一般在几个 Checkpoint 周期内恢复"
    ;;
  after)
    echo "  - 异常类型: Map 算子业务逻辑后抛异常"
    echo "  - 行为: 业务逻辑已执行，但 Task 失败重启，导致同一条记录可能被再次处理"
    echo "  - 理论重复: ≈ 故障概率 × 处理记录数（上界），实际需结合 metrics 中 process_count 观察"
    echo "  - 预期恢复时间: 与 before 类似，由 Flink 重启和 Checkpoint 恢复决定"
    ;;
  *)
    echo "  - 未知异常类型: $FAULT_TYPE (请使用 none/before/after)"
    ;;
esac

echo ""
echo -e "${BLUE}=========================================${NC}"

# 8. 快照管理
if [ "$CREATE_SNAPSHOT" = "yes" ] || [ "$CREATE_SNAPSHOT" = "y" ]; then
    echo -e "${GREEN}📸 创建统计快照...${NC}"
    SNAPSHOT_NOTE="Flink异常测试-$FAULT_TYPE-$(date +'%Y%m%d-%H%M%S')"
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