#!/bin/bash
# ========================================
# 查看实验状态 - 在 Node 1 执行
# 增强版：包含详细指标、快照管理、可视化展示
# ========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}  实验状态监控面板${NC}"
echo -e "${BLUE}=======================================${NC}"
echo ""

# 1. 进程状态检查
echo -e "${YELLOW}【1. 运行状态检查】${NC}"
echo ""

echo -e "${GREEN}数据生成器 (Node 2):${NC}"
ssh node2 "ps aux | grep data-generator.jar | grep -v grep" && echo -e "${GREEN}✓ 运行中${NC}" || echo -e "${RED}✗ 未运行${NC}"
echo ""

echo -e "${GREEN}Flink Jobs:${NC}"
cd /opt/flink && ./bin/flink list 2>/dev/null || echo -e "${RED}✗ 无运行任务${NC}"
echo ""

echo -e "${GREEN}Storm Topologies:${NC}"
cd /opt/storm && ./bin/storm list 2>/dev/null || echo -e "${RED}✗ 无运行任务${NC}"
echo ""

echo -e "${GREEN}指标收集器 (Node 3):${NC}"
ssh node3 "ps aux | grep metrics-collector.jar | grep -v grep" && echo -e "${GREEN}✓ 运行中${NC}" || echo -e "${RED}✗ 未运行${NC}"
echo ""
echo "========================================"
echo ""

# 2. 实时数据统计
echo -e "${YELLOW}【2. 实时数据统计】${NC}"
echo ""

mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT '当前数据量' AS 统计项;
SELECT * FROM v_comparison;
SELECT '';
SELECT '延迟百分位分布' AS 统计项;
SELECT * FROM v_latency_percentiles;
" 2>/dev/null

echo ""
echo "========================================"
echo ""

# 3. 吞吐量趋势（最近10秒）
echo -e "${YELLOW}【3. 吞吐量趋势（最近10秒）】${NC}"
echo ""

mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_throughput_per_second LIMIT 100;
" 2>/dev/null

echo ""
echo "========================================"
echo ""

# 4. 快照管理菜单
echo -e "${YELLOW}【4. 快照管理】${NC}"
echo ""

echo "当前快照数量:"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT job_type, COUNT(*) AS 快照数量 FROM stats_snapshots GROUP BY job_type;
" 2>/dev/null

echo ""
echo "最新5个快照:"
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_snapshot_history LIMIT 5;
" 2>/dev/null

echo ""
echo "========================================"
echo ""

# 5. 操作菜单
echo -e "${BLUE}【快捷操作】${NC}"
echo "1. 创建快照: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_create_snapshot('描述');\""
echo "2. 对比快照: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_compare_snapshots(ID1, ID2);\""
echo "3. 平均统计: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_get_avg_stats('flink', 5);\""
echo "4. 延迟分布: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_get_latency_distribution('storm');\""
echo "5. 查看重复: mysql -h node1 -u exp_user -ppassword stream_experiment -e \"CALL sp_get_duplicates('flink');\""
echo ""
echo -e "${BLUE}=======================================${NC}"
