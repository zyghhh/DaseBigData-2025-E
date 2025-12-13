# Flink vs Storm At-Least-Once 对比实验

完整的流处理系统对比实验项目，用于评估 **Flink** 和 **Storm** 在 **At-Least-Once** 语义下的性能表现。

## 📁 项目结构

```
DaseBigData-2025-E/
├── pom.xml                          # Maven 父工程配置
├── README.md                        # 项目说明（本文件）
├── DEPLOYMENT.md                    # 详细部署文档
│
├── data-generator/                  # 数据生成器模块
│   ├── pom.xml
│   └── src/main/java/com/dase/bigdata/generator/
│       └── DataGenerator.java
│
├── experiment-job/                  # 计算任务模块
│   ├── pom.xml
│   └── src/main/java/com/dase/bigdata/job/
│       ├── FlinkAtLeastOnceJob.java
│       └── StormAtLeastOnceTopology.java
│
├── metrics-collector/               # 指标收集器模块
│   ├── pom.xml
│   └── src/main/java/com/dase/bigdata/collector/
│       └── MetricsCollector.java
│
├── database/                        # 数据库脚本
│   ├── init.sql                    # MySQL 初始化脚本
│   └── init.sh                     # 数据库初始化 Shell 脚本
│
└── scripts/                         # 自动化部署脚本
    ├── cluster-flink-start.sh      # 启动 Flink 集群
    ├── cluster-flink-stop.sh       # 停止 Flink 集群
    ├── cluster-storm-start.sh      # 启动 Storm 集群
    ├── cluster-storm-stop.sh       # 停止 Storm 集群
    ├── start-flink.sh              # 启动 Flink 实验
    ├── start-storm.sh              # 启动 Storm 实验
    ├── stop-all.sh                 # 停止所有实验服务
    └── view-status.sh              # 查看实验状态
```

## 🚀 完整实验流程

### 1. 本地编译项目

```bash
cd D:\vDesktop\DaseBigData-2025-E
mvn clean package
```

### 2. 部署 JAR 包和脚本

使用 XShell + FTP 将文件上传到对应节点：

**Node 1: `/opt/experiment/`**
```
experiment-job.jar          # Flink & Storm 任务
cluster-flink-start.sh      # 启动 Flink 集群
cluster-flink-stop.sh       # 停止 Flink 集群
cluster-storm-start.sh      # 启动 Storm 集群
cluster-storm-stop.sh       # 停止 Storm 集群
start-flink.sh              # 启动 Flink 实验
start-storm.sh              # 启动 Storm 实验
stop-all.sh                 # 停止所有实验
view-status.sh              # 查看状态
```

**Node 2: `/opt/experiment/`**
```
data-generator.jar          # 数据生成器
```

**Node 3: `/opt/experiment/`**
```
metrics-collector.jar       # 指标收集器
```

### 3. 首次初始化数据库（只需一次）

```bash
# 在 Node 1 上执行
ssh node1

# 上传初始化脚本（如果未上传）
# 然后执行：
mysql -u root -p < /opt/experiment/init.sql

# 验证初始化成功
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SHOW TABLES;"
```

### 4. 赋予脚本执行权限（首次）

```bash
cd /opt/experiment
chmod +x *.sh
```

### 5. 运行 Flink 实验

```bash
# 5.1 启动 Flink 集群
cd /opt/experiment
./cluster-flink-start.sh

# 验证集群状态
jps  # 应看到 StandaloneSessionClusterEntrypoint

# 5.2 启动 Flink 实验
./start-flink.sh

# 5.3 等待 10 分钟收集数据...

# 5.4 查看 Flink 结果
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_latency_stats WHERE 任务类型='flink';
SELECT * FROM v_duplicate_stats WHERE 任务类型='flink';
"

# 5.5 停止 Flink 实验
./stop-all.sh

# 5.6 停止 Flink 集群
./cluster-flink-stop.sh
```

### 6. 运行 Storm 实验

```bash
# 6.1 启动 Storm 集群
cd /opt/experiment
./cluster-storm-start.sh

# 验证集群状态
jps  # 应看到 Nimbus, core

# 6.2 启动 Storm 实验（会自动复位数据库）
./start-storm.sh

# 6.3 等待 10 分钟收集数据...

# 6.4 查看 Storm 结果
mysql -h node1 -u exp_user -ppassword stream_experiment -e "
SELECT * FROM v_latency_stats WHERE 任务类型='storm';
SELECT * FROM v_duplicate_stats WHERE 任务类型='storm';
"

# 6.5 停止 Storm 实验
./stop-all.sh

# 6.6 停止 Storm 集群
./cluster-storm-stop.sh
```

### 7. 查看对比结果

```bash
# 综合对比（Flink vs Storm）
mysql -h node1 -u exp_user -ppassword stream_experiment -e "SELECT * FROM v_comparison;"

# 或使用脚本查看
./view-status.sh
```

## 📊 核心功能

### 模块一：Data Generator（数据生成器）

- **功能**：以恒定速率生成带有唯一 ID 和时间戳的 JSON 数据
- **部署位置**：Node 2
- **配置参数**：
  - Topic: `source_data`
  - 速率: 1500 msg/s（可调整）
  - 消息大小: 约 1KB

### 模块二：Experiment Job（计算任务）

#### Flink Job

- **Checkpoint 间隔**：5秒
- **Checkpoint 模式**：AT_LEAST_ONCE
- **并发度**：4
- **业务延迟**：2ms（模拟计算负载）

#### Storm Topology

- **Acker 数量**：1
- **Worker 数量**：4
- **业务延迟**：2ms
- **可靠性保证**：AT_LEAST_ONCE

### 模块三：Metrics Collector（指标收集器）

- **功能**：消费 Sink Topic，计算延迟并检测重复
- **部署位置**：Node 3
- **存储**：MySQL（利用唯一索引检测重复）

## 📈 实验指标

1. **端到端延迟**：消息从生成到被收集的总延迟
2. **重复率**：重复处理的消息占比（At-Least-Once 语义的关键指标）
3. **吞吐量**：系统处理消息的速率
4. **延迟分布**：不同延迟区间的消息分布

## 🔍 数据查询

```sql
-- 查看延迟统计
SELECT * FROM v_latency_stats;

-- 查看重复率统计
SELECT * FROM v_duplicate_stats;

-- 查看综合对比
SELECT * FROM v_comparison;

-- 查看重复消息详情
CALL sp_get_duplicates('flink');

-- 查看延迟分布
CALL sp_get_latency_distribution('flink');

-- 实验复位
CALL sp_reset_experiment();
```

## 🛠️ 技术栈

| 组件 | 版本 | 用途 |
|------|------|------|
| Java | 1.8 | 编程语言 |
| Maven | 3.6+ | 构建工具 |
| Flink | 1.14.6 | 流处理引擎 |
| Storm | 2.4.0 | 流处理引擎 |
| Kafka | 2.8.0 | 消息队列 |
| MySQL | 8.0 | 数据存储 |
| FastJSON | 1.2.83 | JSON 处理 |

## 📖 详细文档

请参阅 [DEPLOYMENT.md](DEPLOYMENT.md) 获取完整的部署和运行指南，包括：

- 环境配置详解
- 分步部署流程
- 故障排查指南
- 实验报告模板

## 🔒 注意事项

1. **安全性**：请修改数据库默认密码（`database/init.sql` 和 `MetricsCollector.java`）
2. **资源限制**：各 jar 包已限制 JVM 内存为 512M
3. **网络配置**：确保各节点的 `/etc/hosts` 配置正确
4. **端口开放**：确保防火墙开放必要端口（Kafka 9092, MySQL 3306, Flink 8081, Storm 8080）

## 📄 许可证

Apache License 2.0

## 👨‍💻 联系方式

如有问题，请检查 `DEPLOYMENT.md` 中的故障排查部分，或查看各模块的日志文件。
