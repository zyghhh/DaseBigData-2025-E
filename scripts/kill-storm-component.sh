#!/bin/bash
# ========================================
# Kill Storm 组件进程（用于异常测试）
# 在 Node 1 执行
# ========================================

COMPONENT=${1:-help}

if [ "$COMPONENT" == "help" ]; then
  echo "用法: ./kill-storm-component.sh <component>"
  echo ""
  echo "可用组件："
  echo "  spout    - Kill Spout 进程"
  echo "  bolt     - Kill Bolt 进程"
  echo "  acker    - Kill Acker 进程"
  echo "  all      - Kill 所有 Storm 进程"
  echo ""
  echo "示例："
  echo "  ./kill-storm-component.sh acker"
  exit 0
fi

echo "=== Kill Storm Component: $COMPONENT ==="

case $COMPONENT in
  spout)
    echo "正在查找 Spout 进程..."
    # 注意：实际的进程名可能不同，需要根据实际情况调整
    ps aux | grep "kafka-spout" | grep -v grep
    ;;
  bolt)
    echo "正在查找 Bolt 进程..."
    ps aux | grep "process-bolt" | grep -v grep
    ;;
  acker)
    echo "正在查找 Acker 进程..."
    # Acker 通常在 worker 进程中，需要识别包含 acker 的 worker
    ACKER_PIDS=$(ps aux | grep storm | grep worker | grep -v grep | awk '{print $2}')
    if [ -z "$ACKER_PIDS" ]; then
      echo "未找到 Acker 进程"
    else
      echo "找到以下 Worker 进程（可能包含 Acker）："
      ps aux | grep storm | grep worker | grep -v grep
      echo ""
      echo "提示：Storm 的 Acker 运行在 worker 进程中"
      echo "建议通过 Storm UI (http://node1:8080) 查看 Acker 所在的 worker"
      echo ""
      read -p "确认要 Kill 这些进程吗？(y/N): " confirm
      if [ "$confirm" == "y" ] || [ "$confirm" == "Y" ]; then
        echo "$ACKER_PIDS" | xargs kill -9
        echo "✓ Acker 进程已 Kill"
      else
        echo "取消操作"
      fi
    fi
    ;;
  all)
    echo "正在 Kill 所有 Storm 进程..."
    ps -ef | grep storm | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null
    echo "✓ 所有 Storm 进程已 Kill"
    ;;
  *)
    echo "错误：未知的组件 $COMPONENT"
    echo "执行 ./kill-storm-component.sh help 查看帮助"
    exit 1
    ;;
esac
