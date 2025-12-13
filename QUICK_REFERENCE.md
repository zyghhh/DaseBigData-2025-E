# ========================================
# Flink vs Storm At-Least-Once 实验快速参考
# ========================================

## 一、编译与部署

### 1.1 本地编译
```bash
cd DaseBigData-2025-E
mvn clean package
```

### 1.2 自动部署
```bash
# 修改 scripts/deploy.sh 中的配置（NODE1, NODE2, NODE3, SSH_USER）
bash scripts/deploy.sh
```

## 二、初始化环境

### 2.1 配置 /etc/hosts（所有节点）
```bash
sudo vim /etc/hosts
# 添加：
# 192.168.1.101  node1
# 192.168.1.102  node2
# 192.168.1.103  node3
```

### 2.2 初始化数据库（Node 1）
```bash
# 方法1：使用脚本（需修改 database/init.sh 中的 root 密码）
bash database/init.sh

# 方法2：手动执行
mysql -u root -p < database/init.sql
```

### 2.3 配置 Storm Worker（Node 2 & Node 3）
```bash
# 编辑 storm.yaml
sudo vim /opt/storm/conf/storm.yaml

# 添加：
supervisor.slots.ports:
    - 6700
    - 6701

# 重启 Supervisor
sudo systemctl restart storm-supervisor
```

## 三、运行实验

### 3.1 Flink 实验
```bash
# 方法1：自动化脚本
bash scripts/start-flink-experiment.sh

# 方法2：手动执行
# (1) 启动数据生成器（Node 2）
ssh node2
cd /opt/experiment
nohup java -Xmx512m -jar data-generator.jar source_data 1500 > generator.log 2>&1 &

# (2) 提交 Flink Job（Node 1）
ssh node1
cd /opt/flink
./bin/flink run -d -c com.dase.bigdata.job.FlinkAtLeastOnceJob experiment-job.jar

# (3) 启动指标收集器（Node 3）
ssh node3
cd /opt/experiment
nohup java -Xmx512m -jar metrics-collector.jar flink_sink flink > collector-flink.log 2>&1 &
```

### 3.2 Storm 实验
```bash
# 方法1：自动化脚本（会自动复位数据库）
bash scripts/start-storm-experiment.sh

# 方法2：手动执行
# (1) 复位数据库
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();"

# (2) 提交 Storm Topology（Node 1）
ssh node1
cd /opt/storm
./bin/storm jar experiment-job.jar com.dase.bigdata.job.StormAtLeastOnceTopology Storm-Test

# (3) 启动指标收集器（Node 3）
ssh node3
cd /opt/experiment
nohup java -Xmx512m -jar metrics-collector.jar storm_sink storm > collector-storm.log 2>&1 &
```

### 3.3 停止所有服务
```bash
bash scripts/stop-all.sh
```

## 四、监控与日志

### 4.1 Web UI
- Flink:  http://node1:8081
- Storm:  http://node1:8080

### 4.2 日志查看
```bash
# 数据生成器日志（Node 2）
ssh node2
tail -f /opt/experiment/generator.log

# Flink 指标收集器日志（Node 3）
ssh node3
tail -f /opt/experiment/collector-flink.log

# Storm 指标收集器日志（Node 3）
ssh node3
tail -f /opt/experiment/collector-storm.log

# Flink JobManager 日志（Node 1）
ssh node1
tail -f /opt/flink/log/flink-*-jobmanager-*.log
```

### 4.3 进程检查
```bash
# 检查数据生成器（Node 2）
ssh node2 "ps aux | grep data-generator.jar"

# 检查 Flink Job（Node 1）
ssh node1 "cd /opt/flink && ./bin/flink list"

# 检查 Storm Topology（Node 1）
ssh node1 "cd /opt/storm && ./bin/storm list"

# 检查指标收集器（Node 3）
ssh node3 "ps aux | grep metrics-collector.jar"
```

## 五、数据分析

### 5.1 实时查询
```bash
# 延迟统计
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_latency_stats;"

# 重复率统计
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_duplicate_stats;"

# 综合对比
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_comparison;"
```

### 5.2 详细分析
```bash
# 连接数据库
mysql -h node1 -u exp_user -ppassword stream_experiment

# 查看重复消息详情
CALL sp_get_duplicates('flink');
CALL sp_get_duplicates('storm');

# 查看延迟分布
CALL sp_get_latency_distribution('flink');
CALL sp_get_latency_distribution('storm');

# 查询特定消息
SELECT * FROM metrics WHERE msg_id = 12345;

# 统计最新1000条消息的平均延迟
SELECT job_type, AVG(latency) as avg_latency 
FROM (SELECT * FROM metrics ORDER BY id DESC LIMIT 1000) t
GROUP BY job_type;
```

### 5.3 数据导出
```bash
# 导出 CSV
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_comparison;" > comparison.csv

# 完整导出
mysqldump -h node1 -u exp_user -ppassword stream_experiment > experiment_backup.sql
```

## 六、故障排查

### 6.1 Kafka 连接问题
```bash
# 检查 Kafka 服务
ssh node1 "jps | grep Kafka"

# 测试连接
telnet node1 9092

# 查看 Topic
kafka-topics.sh --bootstrap-server node1:9092 --list

# 消费测试
kafka-console-consumer.sh --bootstrap-server node1:9092 --topic source_data --from-beginning --max-messages 10
```

### 6.2 数据库连接问题
```bash
# 检查 MySQL 服务
ssh node1 "systemctl status mysql"

# 测试连接
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SHOW TABLES;"

# 检查用户权限
mysql -h node1 -u root -p -e "SELECT user, host FROM mysql.user WHERE user='exp_user';"
```

### 6.3 Flink Job 失败
```bash
# 查看 JobManager 日志
ssh node1 "tail -100 /opt/flink/log/flink-*-jobmanager-*.log"

# 查看 TaskManager 日志
ssh node1 "tail -100 /opt/flink/log/flink-*-taskmanager-*.log"

# 取消 Job
ssh node1 "cd /opt/flink && ./bin/flink cancel <job-id>"
```

### 6.4 Storm Topology 失败
```bash
# 查看 Nimbus 日志
ssh node1 "tail -100 /opt/storm/logs/nimbus.log"

# 查看 Worker 日志
ssh node2 "tail -100 /opt/storm/logs/worker-*.log"

# Kill Topology
ssh node1 "cd /opt/storm && ./bin/storm kill <topology-name> -w 0"
```

## 七、性能调优

### 7.1 调整数据生成速率
```bash
# 停止当前生成器
ssh node2 "pkill -f data-generator.jar"

# 启动新速率（例如 2000 msg/s）
ssh node2 "cd /opt/experiment && nohup java -Xmx512m -jar data-generator.jar source_data 2000 > generator.log 2>&1 &"
```

### 7.2 调整 Checkpoint 间隔
修改 `FlinkAtLeastOnceJob.java` 中的：
```java
env.enableCheckpointing(5000);  // 修改为其他值（毫秒）
```

### 7.3 调整并发度
修改 `FlinkAtLeastOnceJob.java` 中的：
```java
env.setParallelism(4);  // 修改为其他值
```

## 八、实验复位

### 8.1 完全复位
```bash
# 1. 停止所有服务
bash scripts/stop-all.sh

# 2. 清空数据库
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();"

# 3. 重置 Kafka Offset（可选）
kafka-consumer-groups.sh --bootstrap-server node1:9092 \
  --group flink-exp-group --reset-offsets --to-earliest \
  --topic source_data --execute

kafka-consumer-groups.sh --bootstrap-server node1:9092 \
  --group storm-exp-group --reset-offsets --to-earliest \
  --topic source_data --execute
```

### 8.2 切换实验（Flink → Storm）
```bash
# 1. 停止 Flink
bash scripts/stop-all.sh

# 2. 复位数据库
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();"

# 3. 启动 Storm
bash scripts/start-storm-experiment.sh
```

## 九、关键配置参数

### 9.1 Flink At-Least-Once
- Checkpoint 间隔: 5000ms
- Checkpoint 模式: AT_LEAST_ONCE
- 并发度: 4
- 业务延迟: 2ms

### 9.2 Storm At-Least-Once
- Acker 数量: 1
- Worker 数量: 4
- Spout 并发: 1
- Bolt 并发: 2+1
- 业务延迟: 2ms

### 9.3 数据生成器
- Topic: source_data
- 速率: 1500 msg/s
- 消息大小: 1KB
- 格式: JSON (msg_id, create_time, payload)

### 9.4 指标收集器
- Flink Topic: flink_sink
- Storm Topic: storm_sink
- 批量提交: 每次 poll 后
- 重复检测: MySQL 唯一索引

## 十、快速命令索引

```bash
# 编译
mvn clean package

# 部署
bash scripts/deploy.sh

# 启动 Flink 实验
bash scripts/start-flink-experiment.sh

# 启动 Storm 实验
bash scripts/start-storm-experiment.sh

# 停止所有
bash scripts/stop-all.sh

# 查看结果
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_comparison;"

# 复位实验
mysql -h node1 -u exp_user -ppassword stream_experiment -e "CALL sp_reset_experiment();"
```
