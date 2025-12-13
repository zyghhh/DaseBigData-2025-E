#!/bin/bash
# ========================================
# 查看 Storm 异常测试结果
# 在 Node 1 执行
# ========================================

FAULT_TYPE=${1:-none}

echo "=== Storm At-Least-Once 异常测试结果 ($FAULT_TYPE) ==="
echo ""

# 1. 查看延迟统计
echo "📊 延迟统计："
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT 
    任务类型 AS 'Job Type',
    总消息数 AS 'Total Messages',
    平均延迟_ms AS 'Avg Latency (ms)',
    最小延迟_ms AS 'Min Latency (ms)',
    最大延迟_ms AS 'Max Latency (ms)'
FROM v_latency_stats 
WHERE 任务类型 LIKE 'storm-fault-%';
" 2>/dev/null

echo ""

# 2. 查看重复率统计
echo "🔄 重复率统计："
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT 
    任务类型 AS 'Job Type',
    总消息数 AS 'Total Messages',
    唯一消息数 AS 'Unique Messages',
    重复消息数 AS 'Duplicate Messages',
    重复率 AS 'Duplicate Rate (%)'
FROM v_duplicate_stats 
WHERE 任务类型 LIKE 'storm-fault-%';
" 2>/dev/null

echo ""

# 3. 查看重复消息详情（前 20 条）
echo "📋 重复消息详情（Top 20）："
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT 
    msg_id AS 'Message ID',
    process_count AS 'Process Count',
    latency AS 'Latency (ms)'
FROM metrics 
WHERE job_type LIKE 'storm-fault-%' AND process_count > 1
ORDER BY process_count DESC
LIMIT 20;
" 2>/dev/null

echo ""

# 4. 重复次数分布
echo "📈 重复次数分布："
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT 
    process_count AS 'Process Count',
    COUNT(*) AS 'Message Count'
FROM metrics 
WHERE job_type LIKE 'storm-fault-%'
GROUP BY process_count
ORDER BY process_count;
" 2>/dev/null

echo ""

# 5. 计算预期重复数（根据异常类型）
echo "🧮 理论分析："
case $FAULT_TYPE in
  none)
    echo "  - 异常类型: 无异常"
    echo "  - 预期重复: 0"
    ;;
  spout)
    echo "  - 异常类型: Spout 异常"
    echo "  - 理论重复数 ≈ spout.max.pending × 异常次数"
    ;;
  bolt-before)
    echo "  - 异常类型: Bolt emit 之前异常"
    echo "  - 理论重复数: 0（消息不会被 emit）"
    ;;
  bolt-after)
    echo "  - 异常类型: Bolt emit 之后异常"
    echo "  - 理论重复数 = 异常次数"
    ;;
  acker)
    echo "  - 异常类型: Acker 异常（需要手动 Kill）"
    echo "  - 理论重复数 ≈ spout.max.pending × Kill 次数"
    ;;
esac

echo ""
echo "=== 结果分析完成 ==="
