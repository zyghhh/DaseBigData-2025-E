# Storm At-Least-Once 异常注入测试指南

## 📋 测试目标

验证 Storm At-Least-Once 语义下，不同异常场景对消息重复率的影响。

## 🎯 测试场景

| 测试场景 | 异常位置 | 预期重复数 | 脚本参数 |
|---------|---------|-----------|---------|
| 无异常基准测试 | 无 | 0 | `none` |
| Spout 异常 | Kafka Spout | ≈ max.pending × 异常次数 | `spout` |
| Bolt emit 前异常 | Process Bolt (emit 前) | 0 | `bolt-before` |
| Bolt emit 后异常 | Process Bolt (emit 后) | = 异常次数 | `bolt-after` |
| Acker 异常 | Acker 进程 | ≈ max.pending × Kill 次数 | `acker` |

## 🚀 快速开始

### 1. 编译项目（包含新的异常注入代码）

```bash
cd D:\vDesktop\DaseBigData-2025-E
mvn clean package
```

### 2. 上传 JAR 包到集群

```powershell
# 上传到 Node 1
scp experiment-job\target\experiment-job.jar node1:/opt/experiment/
scp data-generator\target\data-generator.jar node2:/opt/experiment/
scp metrics-collector\target\metrics-collector.jar node3:/opt/experiment/

# 上传测试脚本到 Node 1
scp scripts\start-storm-fault-test.sh node1:/opt/experiment/
scp scripts\view-fault-test-result.sh node1:/opt/experiment/
scp scripts\kill-storm-component.sh node1:/opt/experiment/
```

### 3. 赋予脚本执行权限

```bash
cd /opt/experiment
chmod +x start-storm-fault-test.sh view-fault-test-result.sh kill-storm-component.sh
```

## 📊 测试执行

### 测试 1：无异常基准测试

```bash
# 启动 Storm 集群
./cluster-storm-start.sh

# 运行测试（10万条消息，2000 msg/s，max.pending=1000，无异常）
./start-storm-fault-test.sh 100000 2000 1000 none

# 等待处理完成（约 100 秒）
sleep 120

# 查看结果
./view-fault-test-result.sh none

# 预期结果：重复率 = 0%
```

### 测试 2：Bolt emit 前异常

```bash
# 运行测试（异常概率 1%）
./start-storm-fault-test.sh 100000 2000 1000 bolt-before 0.01

# 等待处理完成
sleep 120

# 查看结果
./view-fault-test-result.sh bolt-before

# 预期结果：重复率 = 0%（消息未 emit，不会重复）
```

### 测试 3：Bolt emit 后异常

```bash
# 运行测试（异常概率 1%）
./start-storm-fault-test.sh 100000 2000 1000 bolt-after 0.01

# 等待处理完成
sleep 120

# 查看结果
./view-fault-test-result.sh bolt-after

# 预期结果：重复数 ≈ 100000 × 0.01 = 1000
```

### 测试 4：Acker 异常（手动 Kill）

```bash
# 运行测试
./start-storm-fault-test.sh 100000 2000 1000 acker

# 在数据处理过程中，手动 Kill Acker 进程（重复 3 次）
# 打开另一个终端，执行：
./kill-storm-component.sh acker

# 等待处理完成
sleep 120

# 查看结果
./view-fault-test-result.sh acker

# 预期结果：重复数 ≈ 1000 × 3 = 3000
```

## 📈 结果分析

### 查看详细统计

```bash
# 延迟统计
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_latency_stats WHERE 任务类型 LIKE 'storm-fault-%';"

# 重复率统计
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_duplicate_stats WHERE 任务类型 LIKE 'storm-fault-%';"

# 重复次数分布
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT process_count, COUNT(*) as message_count 
FROM metrics 
WHERE job_type LIKE 'storm-fault-%' 
GROUP BY process_count 
ORDER BY process_count;
"
```

### 对比不同异常类型

```bash
# 综合对比
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT 
    任务类型,
    总消息数,
    唯一消息数,
    重复消息数,
    重复率
FROM v_duplicate_stats
WHERE 任务类型 LIKE 'storm-fault-%'
ORDER BY 任务类型;
"
```

## 🧹 清理测试数据

```bash
# 停止所有服务
./stop-all.sh

# 停止 Storm 集群
./cluster-storm-stop.sh

# 复位数据库
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();"
```

## 🔧 高级配置

### 自定义测试参数

```bash
./start-storm-fault-test.sh <MESSAGE_COUNT> <SPEED> <MAX_PENDING> <FAULT_TYPE> <FAULT_RATE>
```

**参数说明**：
- `MESSAGE_COUNT`：消息总数（默认 100000）
- `SPEED`：发送速率 msg/s（默认 2000）
- `MAX_PENDING`：Spout Max Pending（默认 1000）
- `FAULT_TYPE`：异常类型（none, spout, bolt-before, bolt-after, acker）
- `FAULT_RATE`：异常概率 0.0-1.0（默认 0.01）

**示例**：

```bash
# 50万消息，3000 msg/s，max.pending=2000，Bolt 异常 5%
./start-storm-fault-test.sh 500000 3000 2000 bolt-after 0.05
```

## 📝 实验报告模板

### 测试环境

- Kafka 版本：2.8.0
- Storm 版本：2.4.0
- Worker 配置：4 个（Spout、Process Bolt、Sink Bolt、Acker 隔离）
- 并发度：Spout=1, Process=2, Sink=1, Acker=1
- CPU/内存：1 CPU, 1.6G 内存 per worker

### 测试数据

- 数据规模：10万 ~ 50万条
- 消息唯一性：每个 msg_id 仅出现一次
- 发送速率：2000 msg/s

### 测试结果示例

| 异常类型 | 总消息数 | 唯一消息数 | 重复消息数 | 重复率 | 备注 |
|---------|---------|-----------|-----------|--------|------|
| 无异常 | 100000 | 100000 | 0 | 0% | 基准 |
| Bolt emit 前 | 100000 | 100000 | 0 | 0% | 符合预期 |
| Bolt emit 后 | 100000 | 99000 | 1000 | 1% | ≈ 异常概率 |
| Acker Kill 3次 | 100000 | 97000 | 3000 | 3% | ≈ max.pending × 3 |

## 🚨 注意事项

1. **资源限制**：每次只运行一个测试，避免资源竞争
2. **数据复位**：每次测试前自动复位数据库，确保结果独立
3. **等待时间**：确保所有消息处理完成后再查看结果
4. **Acker Kill**：Acker 异常需要手动 Kill，通过 Storm UI 确认 worker 位置

## 🔍 故障排查

### 问题 1：数据生成器未停止

```bash
# 检查日志
ssh node2 "tail -f /opt/experiment/generator.log"

# 手动停止
ssh node2 "pkill -f DataGenerator"
```

### 问题 2：Storm Topology 未接收数据

```bash
# 检查 Kafka Topic 消息数
/opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list node1:9092 --topic source_data --time -1

# 检查 Storm UI
# 访问 http://node1:8080
```

### 问题 3：重复率与预期不符

- 确认异常配置是否正确传递（查看 Storm 日志）
- 确认 max.pending 配置生效
- 增加等待时间，确保所有消息处理完成
