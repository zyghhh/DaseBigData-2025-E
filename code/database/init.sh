#!/bin/bash
# ========================================
# 数据库初始化脚本 - 自动部署版本
# 在 Node 1 上执行
# ========================================

set -e  # 遇到错误立即退出

# 配置变量
MYSQL_HOST="node1"
MYSQL_PORT="3306"
MYSQL_ROOT_PASSWORD="your_root_password"  # 请修改为实际的 root 密码
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SCRIPT_DIR}/init.sql"

echo "========================================"
echo "Stream Experiment Database Initialization"
echo "========================================"
echo "MySQL Host: ${MYSQL_HOST}:${MYSQL_PORT}"
echo "SQL Script: ${SQL_FILE}"
echo "========================================"

# 检查 SQL 文件是否存在
if [ ! -f "${SQL_FILE}" ]; then
    echo "Error: SQL file not found: ${SQL_FILE}"
    exit 1
fi

# 执行 SQL 脚本
echo "Executing SQL script..."
mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" < "${SQL_FILE}"

if [ $? -eq 0 ]; then
    echo "========================================"
    echo "Database initialized successfully!"
    echo "========================================"
    echo ""
    echo "Quick Test Commands:"
    echo "  mysql -h ${MYSQL_HOST} -u exp_user -ppassword stream_experiment"
    echo "  SELECT * FROM v_latency_stats;"
    echo "  SELECT * FROM v_duplicate_stats;"
    echo ""
else
    echo "Error: Database initialization failed!"
    exit 1
fi
