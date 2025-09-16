-- -- Tạo profile mặc định
-- CREATE SETTINGS PROFILE default SETTINGS max_memory_usage = 10000000000,
-- use_uncompressed_cache = 0,
-- load_balancing = 'in_order',
-- log_queries = 1;

-- -- Quota mặc định (1h không giới hạn)
-- CREATE QUOTA default FOR INTERVAL 1 HOUR MAX QUERIES 0 MAX ERRORS 0 MAX RESULT_ROWS 0 MAX READ_ROWS 0 MAX EXECUTION_TIME 0 TO ALL;

-- -- Tạo user mặc định
-- CREATE USER default IDENTIFIED
-- WITH
--     no_password HOST ANY SETTINGS PROFILE default;

-- GRANT ALL ON *.* TO default;

-- -- Tạo user api
-- CREATE USER api IDENTIFIED
-- WITH
--     plaintext_password BY 'api' HOST ANY SETTINGS PROFILE default;

-- GRANT ALL ON *.* TO api;

-- -- Tạo user worker
-- CREATE USER worker IDENTIFIED
-- WITH
--     plaintext_password BY 'worker' HOST ANY SETTINGS PROFILE default;

-- GRANT ALL ON *.* TO worker;