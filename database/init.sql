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

-- 4. 创建统计快照表（用于复查和历史对比）
DROP TABLE IF EXISTS stats_snapshots;

CREATE TABLE stats_snapshots (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '快照ID',
    snapshot_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '快照时间',
    job_type VARCHAR(20) NOT NULL COMMENT '任务类型',
    
    -- 基础统计
    total_messages BIGINT COMMENT '总消息数',
    unique_messages BIGINT COMMENT '唯一消息数',
    
    -- 延迟指标
    avg_latency DECIMAL(10,2) COMMENT '平均延迟(ms)',
    min_latency BIGINT COMMENT '最小延迟(ms)',
    max_latency BIGINT COMMENT '最大延迟(ms)',
    p50_latency DECIMAL(10,2) COMMENT 'P50延迟(ms)',
    p95_latency DECIMAL(10,2) COMMENT 'P95延迟(ms)',
    p99_latency DECIMAL(10,2) COMMENT 'P99延迟(ms)',
    stddev_latency DECIMAL(10,2) COMMENT '延迟标准差(ms)',
    
    -- 重复率指标
    duplicate_messages BIGINT COMMENT '重复消息数',
    duplicate_rate DECIMAL(10,4) COMMENT '重复率(%)',
    max_process_count INT COMMENT '最大处理次数',
    total_reprocess_count BIGINT COMMENT '总重复处理次数',
    
    -- 吞吐量指标（时间窗口内）
    throughput_per_sec DECIMAL(10,2) COMMENT '吞吐量(msg/s)',
    time_window_sec BIGINT COMMENT '统计时间窗口(秒)',
    
    -- 元信息
    data_range_start BIGINT COMMENT '数据起始时间戳',
    data_range_end BIGINT COMMENT '数据结束时间戳',
    note VARCHAR(200) COMMENT '备注',
    
    INDEX idx_job_snapshot (job_type, snapshot_time),
    INDEX idx_snapshot_time (snapshot_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='实验统计快照表';

-- 5. 创建统计视图

-- 百分位 & 吞吐视图
-- v_latency_percentiles：
-- 用窗口函数近似算 P50 / P95 / P99 延迟（按 job_type）
-- 同样是基于当前 metrics 全量数据
-- v_throughput_per_second：
-- 按 FLOOR(out_time/1000) 做分组，算每秒输出条数
-- 用来看吞吐随时间的变化趋势
-- 这两个都可以用来画时间序列图或看延迟分布


-- 5.1 延迟统计视图
CREATE OR REPLACE VIEW v_latency_stats AS
SELECT 
    job_type AS 任务类型,
    COUNT(*) AS 总消息数,
    ROUND(AVG(latency), 2) AS 平均延迟_ms,
    MIN(latency) AS 最小延迟_ms,
    MAX(latency) AS 最大延迟_ms,
    ROUND(STDDEV(latency), 2) AS 延迟标准差_ms,
    ROUND(AVG(latency) / 1000, 2) AS 平均延迟_s
FROM metrics
GROUP BY job_type;

-- 4.2 重复率统计视图
CREATE OR REPLACE VIEW v_duplicate_stats AS
SELECT 
    job_type AS 任务类型,
    COUNT(*) AS 总消息数,
    SUM(CASE WHEN process_count > 1 THEN 1 ELSE 0 END) AS 重复消息数,
    ROUND(SUM(CASE WHEN process_count > 1 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) AS 重复率_pct,
    MAX(process_count) AS 最大重复次数,
    SUM(process_count - 1) AS 总重复处理次数
FROM metrics
GROUP BY job_type;

-- 4.3 综合对比视图
CREATE OR REPLACE VIEW v_comparison AS
SELECT 
    m.job_type AS 任务类型,
    COUNT(*) AS 总消息数,
    ROUND(AVG(m.latency), 2) AS 平均延迟_ms,
    ROUND(SUM(CASE WHEN m.process_count > 1 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) AS 重复率_pct,
    MAX(m.process_count) AS 最大重复次数
FROM metrics m
GROUP BY m.job_type;

-- 4.4 完整实验统计视图（包含所有指标）
CREATE OR REPLACE VIEW v_experiment_stats AS
SELECT 
    job_type AS 任务类型,
    COUNT(*) AS 处理总消息数,
    COUNT(DISTINCT msg_id) AS 唯一消息数,
    ROUND(COUNT(DISTINCT CASE WHEN process_count > 1 THEN msg_id END) / COUNT(DISTINCT msg_id) * 100, 2) AS 重复消息占比_pct,
    ROUND(AVG(latency), 2) AS 平均延迟_ms,
    MIN(latency) AS 最小延迟_ms,
    MAX(latency) AS 最大延迟_ms,
    -- P95 延迟
    (
        SELECT ROUND(latency, 2) 
        FROM (
            SELECT latency, 
                   ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                   COUNT(*) OVER () AS total
            FROM metrics m2
            WHERE m2.job_type = m1.job_type
        ) ranked
        WHERE rn = FLOOR(total * 0.95)
        LIMIT 1
    ) AS P95延迟_ms,
    -- P99 延迟
    (
        SELECT ROUND(latency, 2) 
        FROM (
            SELECT latency, 
                   ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                   COUNT(*) OVER () AS total
            FROM metrics m2
            WHERE m2.job_type = m1.job_type
        ) ranked
        WHERE rn = FLOOR(total * 0.99)
        LIMIT 1
    ) AS P99延迟_ms,
    COUNT(DISTINCT CASE WHEN process_count > 1 THEN msg_id END) AS 出现重复的消息数,
    ROUND(COUNT(DISTINCT CASE WHEN process_count > 1 THEN msg_id END) / COUNT(DISTINCT msg_id) * 100, 4) AS 重复率_pct,
    MAX(process_count) AS 最大重复次数,
    SUM(process_count - 1) AS 数据重复次数,
    ROUND(COUNT(*) / NULLIF((MAX(out_time) - MIN(out_time)) / 1000.0, 0), 2) AS 吞吐量_msg_s
FROM metrics m1
GROUP BY job_type;

-- 5.5 实时吞吐量视图（按秒统计）
CREATE OR REPLACE VIEW v_throughput_per_second AS
SELECT 
    job_type AS 任务类型,
    FROM_UNIXTIME(FLOOR(out_time/1000)) AS 时间点,
    COUNT(*) AS 每秒消息数
FROM metrics
GROUP BY job_type, FLOOR(out_time/1000), FROM_UNIXTIME(FLOOR(out_time/1000))
ORDER BY FLOOR(out_time/1000) DESC
LIMIT 100;

-- 5.6 延迟百分位统计视图（需MySQL 8.0+）
CREATE OR REPLACE VIEW v_latency_percentiles AS
SELECT 
    job_type AS 任务类型,
    COUNT(*) AS 总消息数,
    ROUND(AVG(latency), 2) AS 平均延迟_ms,
    MIN(latency) AS 最小延迟_ms,
    MAX(latency) AS 最大延迟_ms,
    (
        SELECT ROUND(latency, 2) 
        FROM (
            SELECT latency, 
                   ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                   COUNT(*) OVER () AS total
            FROM metrics m2
            WHERE m2.job_type = m1.job_type
        ) ranked
        WHERE rn = FLOOR(total * 0.50)
        LIMIT 1
    ) AS P50延迟_ms,
    (
        SELECT ROUND(latency, 2) 
        FROM (
            SELECT latency, 
                   ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                   COUNT(*) OVER () AS total
            FROM metrics m2
            WHERE m2.job_type = m1.job_type
        ) ranked
        WHERE rn = FLOOR(total * 0.95)
        LIMIT 1
    ) AS P95延迟_ms,
    (
        SELECT ROUND(latency, 2) 
        FROM (
            SELECT latency, 
                   ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                   COUNT(*) OVER () AS total
            FROM metrics m2
            WHERE m2.job_type = m1.job_type
        ) ranked
        WHERE rn = FLOOR(total * 0.99)
        LIMIT 1
    ) AS P99延迟_ms
FROM metrics m1
GROUP BY job_type;

-- 5.7 快照历史对比视图（完整版）
CREATE OR REPLACE VIEW v_snapshot_history AS
SELECT 
    id AS 快照ID,
    snapshot_time AS 快照时间,
    job_type AS 任务类型,
    total_messages AS 处理总消息数,
    ROUND(avg_latency, 2) AS 平均延迟_ms,
    min_latency AS 最小延迟_ms,
    max_latency AS 最大延迟_ms,
    ROUND(p95_latency, 2) AS P95延迟_ms,
    ROUND(p99_latency, 2) AS P99延迟_ms,
    ROUND(duplicate_rate, 4) AS 重复率_pct,
    max_process_count AS 最大重复次数,
    ROUND(throughput_per_sec, 2) AS 吞吐量_msg_s,
    time_window_sec AS 统计时窗_s,
    note AS 备注
FROM stats_snapshots
ORDER BY snapshot_time DESC;

-- 6. 创建常用查询存储过程
DELIMITER //

-- 6.1 实验复位存储过程（保留快照历史）
DROP PROCEDURE IF EXISTS sp_reset_experiment;
CREATE PROCEDURE sp_reset_experiment()
BEGIN
    TRUNCATE TABLE metrics;
    SELECT 'Experiment data reset successfully! (Snapshots preserved)' AS message;
END //

-- 6.2 创建统计快照存储过程（增强版）
DROP PROCEDURE IF EXISTS sp_create_snapshot;
CREATE PROCEDURE sp_create_snapshot(IN p_note VARCHAR(200))
BEGIN
    INSERT INTO stats_snapshots (
        job_type, total_messages, unique_messages,
        avg_latency, min_latency, max_latency, 
        p50_latency, p95_latency, p99_latency, stddev_latency,
        duplicate_messages, duplicate_rate, max_process_count, total_reprocess_count,
        throughput_per_sec, time_window_sec,
        data_range_start, data_range_end, note
    )
    SELECT 
        job_type,
        COUNT(*) AS total_messages,
        COUNT(DISTINCT msg_id) AS unique_messages,
        
        ROUND(AVG(latency), 2) AS avg_latency,
        MIN(latency) AS min_latency,
        MAX(latency) AS max_latency,
        
        -- P50
        (
            SELECT ROUND(latency, 2)
            FROM (
                SELECT latency, 
                       ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                       COUNT(*) OVER () AS total
                FROM metrics m2
                WHERE m2.job_type = m1.job_type
            ) ranked
            WHERE rn = FLOOR(total * 0.50)
            LIMIT 1
        ) AS p50_latency,
        
        -- P95
        (
            SELECT ROUND(latency, 2)
            FROM (
                SELECT latency, 
                       ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                       COUNT(*) OVER () AS total
                FROM metrics m2
                WHERE m2.job_type = m1.job_type
            ) ranked
            WHERE rn = FLOOR(total * 0.95)
            LIMIT 1
        ) AS p95_latency,
        
        -- P99
        (
            SELECT ROUND(latency, 2)
            FROM (
                SELECT latency, 
                       ROW_NUMBER() OVER (ORDER BY latency) AS rn,
                       COUNT(*) OVER () AS total
                FROM metrics m2
                WHERE m2.job_type = m1.job_type
            ) ranked
            WHERE rn = FLOOR(total * 0.99)
            LIMIT 1
        ) AS p99_latency,
        
        ROUND(STDDEV(latency), 2) AS stddev_latency,
        
        COUNT(DISTINCT CASE WHEN process_count > 1 THEN msg_id END) AS duplicate_messages,
        ROUND(COUNT(DISTINCT CASE WHEN process_count > 1 THEN msg_id END) / COUNT(DISTINCT msg_id) * 100, 4) AS duplicate_rate,
        MAX(process_count) AS max_process_count,
        SUM(process_count - 1) AS total_reprocess_count,
        
        -- 吞吐量计算
        ROUND(COUNT(*) / NULLIF((MAX(out_time) - MIN(out_time)) / 1000.0, 0), 2) AS throughput_per_sec,
        ROUND((MAX(out_time) - MIN(out_time)) / 1000.0, 0) AS time_window_sec,
        
        MIN(event_time) AS data_range_start,
        MAX(out_time) AS data_range_end,
        p_note AS note
    FROM metrics m1
    GROUP BY job_type;
    
    -- 显示创建成功消息
    SELECT CONCAT('快照创建成功 - ', p_note) AS 消息;
    
    -- 显示完整的快照统计信息
    SELECT 
        job_type AS 任务类型,
        total_messages AS 处理总消息数,
        ROUND(avg_latency, 2) AS 平均延迟_ms,
        min_latency AS 最小延迟_ms,
        max_latency AS 最大延迟_ms,
        ROUND(p95_latency, 2) AS P95延迟_ms,
        ROUND(p99_latency, 2) AS P99延迟_ms,
        ROUND(duplicate_rate, 4) AS 重复率_pct,
        max_process_count AS 最大重复次数,
        ROUND(throughput_per_sec, 2) AS 吞吐量_msg_s
    FROM stats_snapshots
    WHERE snapshot_time = (SELECT MAX(snapshot_time) FROM stats_snapshots)
    ORDER BY job_type;
END //

-- 6.3 查询指定任务的重复消息详情
DROP PROCEDURE IF EXISTS sp_get_duplicates;
CREATE PROCEDURE sp_get_duplicates(IN p_job_type VARCHAR(20))
BEGIN
    SELECT 
        msg_id AS 消息ID,
        process_count AS 处理次数,
        latency AS 延迟_ms,
        FROM_UNIXTIME(event_time/1000) AS 创建时间
    FROM metrics
    WHERE job_type = p_job_type AND process_count > 1
    ORDER BY process_count DESC, msg_id
    LIMIT 100;
END //

-- 6.4 查询延迟分布（按区间统计）
DROP PROCEDURE IF EXISTS sp_get_latency_distribution;
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
        END AS 延迟区间,
        COUNT(*) AS 消息数量,
        ROUND(COUNT(*) / (SELECT COUNT(*) FROM metrics WHERE job_type = p_job_type) * 100, 2) AS 占比_pct
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

DELIMITER //

-- 6.5 对比两个快照的差异
DROP PROCEDURE IF EXISTS sp_compare_snapshots;
CREATE PROCEDURE sp_compare_snapshots(IN p_snapshot_id1 BIGINT, IN p_snapshot_id2 BIGINT)
BEGIN
    SELECT 
        s1.job_type AS 任务类型,
        s1.snapshot_time AS 快照1时间,
        s2.snapshot_time AS 快照2时间,
        s1.total_messages AS 快照1消息数,
        s2.total_messages AS 快照2消息数,
        (s2.total_messages - s1.total_messages) AS 消息数增量,
        s1.avg_latency AS 快照1平均延迟,
        s2.avg_latency AS 快照2平均延迟,
        ROUND(s2.avg_latency - s1.avg_latency, 2) AS 平均延迟变化,
        s1.p99_latency AS 快照1_P99延迟,
        s2.p99_latency AS 快照2_P99延迟,
        s1.duplicate_rate AS 快照1重复率,
        s2.duplicate_rate AS 快照2重复率,
        ROUND(s2.duplicate_rate - s1.duplicate_rate, 4) AS 重复率变化,
        s1.throughput_per_sec AS 快照1吞吐量,
        s2.throughput_per_sec AS 快照2吞吐量
    FROM stats_snapshots s1
    JOIN stats_snapshots s2 ON s1.job_type = s2.job_type
    WHERE s1.id = p_snapshot_id1 AND s2.id = p_snapshot_id2;
END //

-- 6.6 查询最新N个快照的平均统计
DROP PROCEDURE IF EXISTS sp_get_avg_stats;
CREATE PROCEDURE sp_get_avg_stats(IN p_job_type VARCHAR(20), IN p_last_n INT)
BEGIN
    SELECT 
        p_job_type AS 任务类型,
        COUNT(*) AS 快照数量,
        ROUND(AVG(avg_latency), 2) AS 平均延迟_均值_ms,
        ROUND(AVG(p99_latency), 2) AS P99延迟_均值_ms,
        ROUND(AVG(duplicate_rate), 4) AS 重复率_均值_pct,
        ROUND(AVG(throughput_per_sec), 2) AS 吞吐量_均值_msg_s,
        MIN(snapshot_time) AS 时间范围起始,
        MAX(snapshot_time) AS 时间范围结束
    FROM (
        SELECT * FROM stats_snapshots 
        WHERE job_type = p_job_type 
        ORDER BY snapshot_time DESC 
        LIMIT p_last_n
    ) recent_snapshots;
END //

DELIMITER ;

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
SELECT '4. 查看延迟百分位: SELECT * FROM v_latency_percentiles;' AS '';
SELECT '5. 查看吞吐量: SELECT * FROM v_throughput_per_second;' AS '';
SELECT '6. 创建快照: CALL sp_create_snapshot(''实验阶段描述'');' AS '';
SELECT '7. 查看快照历史: SELECT * FROM v_snapshot_history;' AS '';
SELECT '8. 对比快照: CALL sp_compare_snapshots(1, 2);' AS '';
SELECT '9. 最近N次平均: CALL sp_get_avg_stats(''flink'', 5);' AS '';
SELECT '10. 复位实验: CALL sp_reset_experiment();' AS '';
SELECT '========================================' AS '';
