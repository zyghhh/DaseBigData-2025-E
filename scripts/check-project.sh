#!/bin/bash
# ========================================
# 项目完整性检查脚本
# 验证所有必需文件是否存在
# ========================================

echo "=========================================="
echo "项目完整性检查"
echo "=========================================="
echo ""

# 项目根目录
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# 检查计数器
TOTAL=0
PASS=0
FAIL=0

# 检查文件函数
check_file() {
    TOTAL=$((TOTAL + 1))
    if [ -f "$1" ]; then
        echo "✓ $1"
        PASS=$((PASS + 1))
    else
        echo "✗ $1 (缺失)"
        FAIL=$((FAIL + 1))
    fi
}

# 检查目录函数
check_dir() {
    TOTAL=$((TOTAL + 1))
    if [ -d "$1" ]; then
        echo "✓ $1/"
        PASS=$((PASS + 1))
    else
        echo "✗ $1/ (缺失)"
        FAIL=$((FAIL + 1))
    fi
}

echo "== 1. 检查项目文档 =="
check_file "README.md"
check_file "DEPLOYMENT.md"
check_file "QUICK_REFERENCE.md"
check_file "PROJECT_SUMMARY.md"
check_file "pom.xml"
echo ""

echo "== 2. 检查 data-generator 模块 =="
check_dir "data-generator"
check_file "data-generator/pom.xml"
check_file "data-generator/src/main/java/com/dase/bigdata/generator/DataGenerator.java"
check_file "data-generator/src/main/resources/logback.xml"
echo ""

echo "== 3. 检查 experiment-job 模块 =="
check_dir "experiment-job"
check_file "experiment-job/pom.xml"
check_file "experiment-job/src/main/java/com/dase/bigdata/job/FlinkAtLeastOnceJob.java"
check_file "experiment-job/src/main/java/com/dase/bigdata/job/StormAtLeastOnceTopology.java"
check_file "experiment-job/src/main/resources/logback.xml"
echo ""

echo "== 4. 检查 metrics-collector 模块 =="
check_dir "metrics-collector"
check_file "metrics-collector/pom.xml"
check_file "metrics-collector/src/main/java/com/dase/bigdata/collector/MetricsCollector.java"
check_file "metrics-collector/src/main/resources/logback.xml"
echo ""

echo "== 5. 检查数据库脚本 =="
check_dir "database"
check_file "database/init.sql"
check_file "database/init.sh"
echo ""

echo "== 6. 检查自动化脚本 =="
check_dir "scripts"
check_file "scripts/deploy.sh"
check_file "scripts/start-flink-experiment.sh"
check_file "scripts/start-storm-experiment.sh"
check_file "scripts/stop-all.sh"
echo ""

echo "== 7. 检查配置示例 =="
check_dir "config"
check_file "config/hosts.example"
check_file "config/storm-config.yaml"
check_file "config/database-config.example"
echo ""

echo "=========================================="
echo "检查结果汇总"
echo "=========================================="
echo "总计: $TOTAL 项"
echo "通过: $PASS 项"
echo "失败: $FAIL 项"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✅ 项目完整性检查通过！"
    echo ""
    echo "下一步操作："
    echo "1. 编译项目：mvn clean package"
    echo "2. 查看部署文档：cat DEPLOYMENT.md"
    echo "3. 查看快速参考：cat QUICK_REFERENCE.md"
    exit 0
else
    echo "❌ 项目缺失 $FAIL 个文件/目录，请检查！"
    exit 1
fi
