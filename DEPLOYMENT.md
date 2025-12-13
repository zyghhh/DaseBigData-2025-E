# Flink vs Storm At-Least-Once 对比实验项目

## 📋 项目概述

这是一个完整的流处理系统对比实验项目，用于评估 **Flink** 和 **Storm** 在 **At-Least-Once** 语义下的性能表现（延迟、重复率）。

### 系统架构

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐      ┌──────────────┐
│ Data        │      │ Kafka        │      │ Flink/Storm │      │ Kafka        │
│ Generator   │─────▶│ source_data  │─────▶│ Processing  │─────▶│ *_sink       │
│ (Node 2)    │      │              │      │ (Node 1,2,3)│      │              │
└─────────────┘      └──────────────┘      └─────────────┘      └──────────────┘
                                                                        │
                                                                        ▼
                                                              ┌──────────────┐
                                                              │ Metrics      │
                                                              │ Collector    │
                                                              │ (Node 3)     │
                                                              └──────────────┘
                                                                        │
                                                                        ▼
                                                              ┌──────────────┐
                                                              │ MySQL        │
                                                              │ (Node 1)     │
                                                              └──────────────┘
```

### 核心模块

1. **data-generator**: Kafka 数据生成器，模拟恒定速率的数据流
2. **experiment-job**: Flink 和 Storm 计算任务，开启 At-Least-Once 可靠性保证
3. **metrics-collector**: 指标收集器，统计延迟和重复率

---

## 🚀 快速开始

### 1. 环境准备

确保以下服务已在集群中正确部署：

- **Kafka** (Node 1, 2, 3): 端口 9092
- **Flink** (Node 1): JobManager + TaskManager (4 Slots)
- **Storm** (Node 1): Nimbus; (Node 2, 3): Supervisor (各2个Worker端口)
- **MySQL** (Node 1): 端口 3306
- **Java 8** 已安装在所有节点

### 2. 配置 /etc/hosts

在 **Node 2** 和 **Node 3** 上配置主机名映射：

```bash
sudo vim /etc/hosts

# 添加以下内容 (替换为实际内网 IP)
192.168.1.101  node1
192.168.1.102  node2
192.168.1.103  node3
```

### 3. 初始化数据库

在 **Node 1** 上执行：

```bash
# 修改 database/init.sh 中的 root 密码
vim database/init.sh  # 修改 MYSQL_ROOT_PASSWORD

# 执行初始化
bash database/init.sh

# 或手动执行
mysql -u root -p < database/init.sql
```

验证：

```bash
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_latency_stats;"
```

### 4. 编译项目

在项目根目录执行：

```bash
mvn clean package

# 生成的 jar 包：
# - data-generator/target/data-generator.jar
# - experiment-job/target/experiment-job.jar
# - metrics-collector/target/metrics-collector.jar
```

---

## 📦 部署与运行

### 步骤 1: 启动数据生成器（Node 2）

```bash
# 上传 jar 包到 Node 2
scp data-generator/target/data-generator.jar user@node2:/opt/experiment/

# 在 Node 2 上启动（每秒 1500 条消息）
ssh node2
cd /opt/experiment
nohup java -Xmx512m -jar data-generator.jar source_data 1500 > generator.log 2>&1 &
```

验证：

```bash
tail -f generator.log
# 应看到 "Data Generator Started" 和定期的统计信息
```

### 步骤 2A: 运行 Flink 实验

#### 2A.1 提交 Flink Job (Node 1)

```bash
# 上传 jar 包到 Node 1
scp experiment-job/target/experiment-job.jar user@node1:/opt/flink/

# 在 Node 1 上提交任务
ssh node1
cd /opt/flink
./bin/flink run -d -c com.dase.bigdata.job.FlinkAtLeastOnceJob experiment-job.jar
```

验证：

```bash
./bin/flink list
# 查看 Web UI: http://node1:8081
```

#### 2A.2 启动指标收集器 (Node 3)

```bash
# 上传 jar 包到 Node 3
scp metrics-collector/target/metrics-collector.jar user@node3:/opt/experiment/

# 在 Node 3 上启动
ssh node3
cd /opt/experiment
nohup java -Xmx512m -jar metrics-collector.jar flink_sink flink > collector-flink.log 2>&1 &
```

验证：

```bash
tail -f collector-flink.log
# 应看到 "Metrics Collector Started" 和定期的统计信息
```

#### 2A.3 运行实验（建议 10 分钟）

等待 10 分钟，让系统积累足够数据...

#### 2A.4 查看 Flink 实验结果

```bash
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_latency_stats WHERE 任务类型='flink';
SELECT * FROM v_duplicate_stats WHERE 任务类型='flink';
"
```

#### 2A.5 停止 Flink 实验

```bash
# 停止 Flink Job
ssh node1
cd /opt/flink
./bin/flink list
./bin/flink cancel <job-id>

# 停止指标收集器
ssh node3
pkill -f metrics-collector
```

### 步骤 2B: 运行 Storm 实验

#### 2B.1 复位实验环境

```bash
# 清空数据库
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();"

# 重置 Kafka Topic Offset (可选)
ssh node1
kafka-consumer-groups.sh --bootstrap-server node1:9092 --group storm-exp-group --reset-offsets --to-earliest --topic source_data --execute
```

#### 2B.2 调整 Storm Worker 配置 (Node 2 & Node 3)

```bash
# 在 Node 2 和 Node 3 上编辑 storm.yaml
ssh node2
sudo vim /opt/storm/conf/storm.yaml

# 修改 Worker 端口配置
supervisor.slots.ports:
    - 6700
    - 6701

# 重启 Supervisor
sudo systemctl restart storm-supervisor

# 在 Node 3 上重复相同操作
```

#### 2B.3 提交 Storm Topology (Node 1)

```bash
# 在 Node 1 上提交
ssh node1
cd /opt/storm
./bin/storm jar /opt/flink/experiment-job.jar com.dase.bigdata.job.StormAtLeastOnceTopology Storm-AtLeastOnce-Test
```

验证：

```bash
./bin/storm list
# 查看 Web UI: http://node1:8080
```

#### 2B.4 启动指标收集器 (Node 3)

```bash
ssh node3
cd /opt/experiment
nohup java -Xmx512m -jar metrics-collector.jar storm_sink storm > collector-storm.log 2>&1 &
```

#### 2B.5 运行实验（建议 10 分钟）

等待 10 分钟...

#### 2B.6 查看 Storm 实验结果

```bash
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_latency_stats WHERE 任务类型='storm';
SELECT * FROM v_duplicate_stats WHERE 任务类型='storm';
"
```

#### 2B.7 停止 Storm 实验

```bash
# 停止 Storm Topology
ssh node1
cd /opt/storm
./bin/storm kill Storm-AtLeastOnce-Test

# 停止指标收集器
ssh node3
pkill -f metrics-collector
```

### 步骤 3: 对比分析

查看两个系统的综合对比：

```bash
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_comparison;"
```

示例输出：

```
+------------+--------------+------------------+--------------+------------------+
| 任务类型   | 总消息数     | 平均延迟(ms)     | 重复率(%)    | 最大重复次数     |
+------------+--------------+------------------+--------------+------------------+
| flink      |       900000 |           45.23  |         0.15 |                2 |
| storm      |       900000 |           52.67  |         1.23 |                3 |
+------------+--------------+------------------+--------------+------------------+
```

---

## 🔧 关键配置说明

### Flink At-Least-Once 配置

- **Checkpoint 间隔**: 5秒
- **Checkpoint 模式**: `AT_LEAST_ONCE`
- **并发度**: 4
- **业务处理延迟**: 2ms

### Storm At-Least-Once 配置

- **Acker 数量**: 1
- **Worker 数量**: 4
- **Spout 并发**: 1
- **Process Bolt 并发**: 2
- **Sink Bolt 并发**: 1
- **业务处理延迟**: 2ms

### 数据生成器配置

- **消息速率**: 1500 msg/s（可调整）
- **消息大小**: 约 1KB
- **消息格式**: JSON (包含 msg_id, create_time, payload)

### 指标收集器配置

- **批量提交**: 每次 poll 后批量写入 MySQL
- **重复检测**: 利用 MySQL 唯一索引 (job_type, msg_id)
- **延迟计算**: out_time - create_time

---

## 📊 数据分析

### 常用查询

```sql
-- 1. 查看延迟统计
SELECT * FROM v_latency_stats;

-- 2. 查看重复率统计
SELECT * FROM v_duplicate_stats;

-- 3. 查看综合对比
SELECT * FROM v_comparison;

-- 4. 查看 Flink 的重复消息详情
CALL sp_get_duplicates('flink');

-- 5. 查看 Storm 的延迟分布
CALL sp_get_latency_distribution('storm');

-- 6. 查询特定消息的处理记录
SELECT * FROM metrics WHERE msg_id = 12345 ORDER BY job_type;

-- 7. 实验复位
CALL sp_reset_experiment();
```

### 导出实验数据

```bash
# 导出到 CSV
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_comparison;" > comparison_result.csv

# 导出完整数据
mysqldump -h node1 -u exp_user -ppassword stream_experiment metrics > metrics_dump.sql
```

---

## 🛠️ 故障排查

### 问题 1: 数据生成器无法连接 Kafka

```bash
# 检查 Kafka 是否运行
ssh node1
jps | grep Kafka

# 检查 /etc/hosts 配置
cat /etc/hosts | grep node

# 测试网络连通性
telnet node1 9092
```

### 问题 2: Flink Job 提交失败

```bash
# 检查 Flink 集群状态
./bin/flink list

# 查看 JobManager 日志
tail -f log/flink-*-jobmanager-*.log

# 检查 TaskManager Slots
# Web UI: http://node1:8081/#/task-managers
```

### 问题 3: 指标收集器无数据

```bash
# 检查 Kafka Topic 是否有数据
kafka-console-consumer.sh --bootstrap-server node1:9092 --topic flink_sink --from-beginning --max-messages 10

# 检查数据库连接
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT COUNT(*) FROM metrics;"

# 查看日志
tail -f collector-flink.log
```

### 问题 4: Storm Worker 不足

```bash
# 检查 Supervisor 配置
ssh node2
cat /opt/storm/conf/storm.yaml | grep slots.ports

# 重启 Supervisor
sudo systemctl restart storm-supervisor

# 查看 Storm UI
# http://node1:8080
```

---

## 📝 实验报告模板

### 1. 实验环境

| 组件   | 版本   | 节点分布      | 配置参数         |
|--------|--------|---------------|------------------|
| Kafka  | 2.8.0  | Node 1,2,3    | 3 Brokers        |
| Flink  | 1.14.6 | Node 1        | 4 Slots          |
| Storm  | 2.4.0  | Node 1,2,3    | 4 Workers        |
| MySQL  | 8.0    | Node 1        | InnoDB           |

### 2. 实验参数

- **数据速率**: 1500 msg/s
- **消息大小**: 1KB
- **业务延迟**: 2ms
- **实验时长**: 10 分钟
- **Checkpoint间隔**: 5s

### 3. 实验结果

| 指标           | Flink    | Storm    | 对比     |
|----------------|----------|----------|----------|
| 平均延迟 (ms)  | 45.23    | 52.67    | Flink 优 |
| 重复率 (%)     | 0.15     | 1.23     | Flink 优 |
| 吞吐量 (msg/s) | 1498     | 1495     | 相近     |

### 4. 结论

（根据实际数据填写）

---

## 🔒 安全注意事项

1. **数据库密码**: 请修改 `database/init.sql` 和 `MetricsCollector.java` 中的默认密码
2. **网络隔离**: 建议在内网环境运行，避免暴露到公网
3. **资源限制**: 启动 jar 包时已限制 JVM 内存（512M），避免资源抢占

---

## 📚 参考资料

- [Flink Checkpointing 文档](https://nightlies.apache.org/flink/flink-docs-release-1.14/docs/dev/datastream/fault-tolerance/checkpointing/)
- [Storm Guarantees 文档](https://storm.apache.org/releases/current/Guaranteeing-message-processing.html)
- [Kafka Producer 配置](https://kafka.apache.org/documentation/#producerconfigs)

---

## 👥 项目信息

- **项目名称**: Flink vs Storm At-Least-Once 对比实验
- **版本**: 1.0-SNAPSHOT
- **许可**: Apache License 2.0

---

## 📞 问题反馈

如遇到问题，请检查：
1. 各节点的 `/etc/hosts` 配置
2. 所有服务（Kafka, Flink, Storm, MySQL）的运行状态
3. 防火墙和网络端口是否开放
4. 日志文件中的错误信息
