-- ========================================
-- Stream Processing Experiment Database
-- At-Least-Once 对比实验数据库初始化脚本
-- ========================================

-- 1. 创建数据库
CREATE DATABASE IF NOT EXISTS stream_experiment 
DEFAULT CHARACTER SET utf8mb4 
DEFAULT COLLATE utf8mb4_unicode_ci;

USE stream_experiment;

-- 2. 创建用户并授权
CREATE USER IF NOT EXISTS 'exp_user'@'%' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON stream_experiment.* TO 'exp_user'@'%';
FLUSH PRIVILEGES;

-- 3. 创建指标表
DROP TABLE IF EXISTS metrics;

CREATE TABLE metrics (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '自增主键',
    job_type VARCHAR(20) NOT NULL COMMENT '任务类型: flink 或 storm',
    msg_id BIGINT NOT NULL COMMENT '消息唯一ID',
    event_time BIGINT NOT NULL COMMENT '消息创建时间(毫秒时间戳)',
    out_time BIGINT NOT NULL COMMENT '消息出队时间(毫秒时间戳)',
    latency BIGINT NOT NULL COMMENT '端到端延迟(毫秒)',
    process_count INT DEFAULT 1 COMMENT '处理次数(用于检测重复)',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '记录创建时间',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '记录更新时间',
    
    -- [实验关键] 联合唯一索引：利用主键冲突检测重复消息
    UNIQUE KEY uk_job_msg (job_type, msg_id),
    
    -- 性能优化索引
    INDEX idx_job_type (job_type),
    INDEX idx_event_time (event_time),
    INDEX idx_latency (latency),
    INDEX idx_process_count (process_count)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='实验指标数据表';

-- 4. 创建统计视图
-- 4.1 延迟统计视图
CREATE OR REPLACE VIEW v_latency_stats AS
SELECT 
    job_type AS '任务类型',
    COUNT(*) AS '总消息数',
    ROUND(AVG(latency), 2) AS '平均延迟(ms)',
    MIN(latency) AS '最小延迟(ms)',
    MAX(latency) AS '最大延迟(ms)',
    ROUND(STDDEV(latency), 2) AS '延迟标准差(ms)',
    ROUND(AVG(latency) / 1000, 2) AS '平均延迟(s)'
FROM metrics
GROUP BY job_type;

-- 4.2 重复率统计视图
CREATE OR REPLACE VIEW v_duplicate_stats AS
SELECT 
    job_type AS '任务类型',
    COUNT(*) AS '总消息数',
    SUM(CASE WHEN process_count > 1 THEN 1 ELSE 0 END) AS '重复消息数',
    ROUND(SUM(CASE WHEN process_count > 1 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) AS '重复率(%)',
    MAX(process_count) AS '最大重复次数',
    SUM(process_count - 1) AS '总重复处理次数'
FROM metrics
GROUP BY job_type;

-- 4.3 综合对比视图
CREATE OR REPLACE VIEW v_comparison AS
SELECT 
    m.job_type AS '任务类型',
    COUNT(*) AS '总消息数',
    ROUND(AVG(m.latency), 2) AS '平均延迟(ms)',
    ROUND(SUM(CASE WHEN m.process_count > 1 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) AS '重复率(%)',
    MAX(m.process_count) AS '最大重复次数'
FROM metrics m
GROUP BY m.job_type;

-- 5. 创建常用查询存储过程
DELIMITER //

-- 5.1 实验复位存储过程
CREATE PROCEDURE sp_reset_experiment()
BEGIN
    TRUNCATE TABLE metrics;
    SELECT 'Experiment data reset successfully!' AS message;
END //

-- 5.2 查询指定任务的重复消息详情
CREATE PROCEDURE sp_get_duplicates(IN p_job_type VARCHAR(20))
BEGIN
    SELECT 
        msg_id AS '消息ID',
        process_count AS '处理次数',
        latency AS '延迟(ms)',
        FROM_UNIXTIME(event_time/1000) AS '创建时间'
    FROM metrics
    WHERE job_type = p_job_type AND process_count > 1
    ORDER BY process_count DESC, msg_id
    LIMIT 100;
END //

-- 5.3 查询延迟分布（按区间统计）
CREATE PROCEDURE sp_get_latency_distribution(IN p_job_type VARCHAR(20))
BEGIN
    SELECT 
        CASE 
            WHEN latency < 100 THEN '0-100ms'
            WHEN latency < 500 THEN '100-500ms'
            WHEN latency < 1000 THEN '500-1000ms'
            WHEN latency < 2000 THEN '1-2s'
            WHEN latency < 5000 THEN '2-5s'
            ELSE '>5s'
        END AS '延迟区间',
        COUNT(*) AS '消息数量',
        ROUND(COUNT(*) / (SELECT COUNT(*) FROM metrics WHERE job_type = p_job_type) * 100, 2) AS '占比(%)'
    FROM metrics
    WHERE job_type = p_job_type
    GROUP BY 
        CASE 
            WHEN latency < 100 THEN '0-100ms'
            WHEN latency < 500 THEN '100-500ms'
            WHEN latency < 1000 THEN '500-1000ms'
            WHEN latency < 2000 THEN '1-2s'
            WHEN latency < 5000 THEN '2-5s'
            ELSE '>5s'
        END
    ORDER BY MIN(latency);
END //

DELIMITER ;

-- 6. 插入测试数据（可选）
-- INSERT INTO metrics (job_type, msg_id, event_time, out_time, latency, process_count)
-- VALUES 
--     ('flink', 1, 1702444800000, 1702444800050, 50, 1),
--     ('storm', 1, 1702444800000, 1702444800055, 55, 1);

-- 7. 显示初始化结果
SELECT '========================================' AS '';
SELECT 'Database Initialization Complete!' AS '';
SELECT '========================================' AS '';
SELECT * FROM v_latency_stats;
SELECT * FROM v_duplicate_stats;

-- 8. 显示可用的查询命令
SELECT '========================================' AS '';
SELECT 'Available Commands:' AS '';
SELECT '========================================' AS '';
SELECT '1. 查看延迟统计: SELECT * FROM v_latency_stats;' AS '';
SELECT '2. 查看重复率统计: SELECT * FROM v_duplicate_stats;' AS '';
SELECT '3. 查看综合对比: SELECT * FROM v_comparison;' AS '';
SELECT '4. 复位实验: CALL sp_reset_experiment();' AS '';
SELECT '5. 查看重复消息: CALL sp_get_duplicates(''flink'');' AS '';
SELECT '6. 查看延迟分布: CALL sp_get_latency_distribution(''flink'');' AS '';
SELECT '========================================' AS '';
