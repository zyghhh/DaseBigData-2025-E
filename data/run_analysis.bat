@echo off
REM ========================================
REM Flink vs Storm 实验数据分析脚本
REM Windows批处理版本
REM ========================================

echo ========================================
echo Flink vs Storm 实验数据分析
echo ========================================
echo.

REM 检查Python是否安装
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo [错误] 未找到Python，请先安装Python 3.x
    pause
    exit /b 1
)

REM 检查必要的Python包
echo [1/3] 检查依赖包...
python -c "import pandas; import matplotlib; import numpy" >nul 2>&1
if %errorlevel% neq 0 (
    echo [提示] 缺少必要的Python包，正在安装...
    pip install pandas matplotlib numpy
    if %errorlevel% neq 0 (
        echo [错误] 安装依赖包失败
        pause
        exit /b 1
    )
)

echo [2/3] 运行数据分析脚本...
python analyze_experiment_results.py
if %errorlevel% neq 0 (
    echo [错误] 脚本执行失败
    pause
    exit /b 1
)

echo.
echo [3/3] 打开结果文件夹...
if exist "figures\" (
    start figures\
) else (
    echo [警告] figures文件夹不存在
)

echo.
echo ========================================
echo 分析完成！
echo ========================================
echo.
echo 生成的图表位于: figures\
echo 汇总报告位于: figures\experiment_summary_report.txt
echo.
pause
