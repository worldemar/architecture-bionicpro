from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.operators.python import PythonOperator
import pandas as pd
import requests
import logging

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2026, 1, 1),
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

def extract_transform_load():
    # 1. Извлекаем данные из CRM (связка пользователя и протеза)
    pg_crm_hook = PostgresHook(postgres_conn_id='CRM_DB_CONN')
    crm_df = pg_crm_hook.get_pandas_df("SELECT user_id, prosthesis_id FROM crm_users")
    logging.info(f"Extracted {len(crm_df)} users from CRM")
    
    # 2. Извлекаем данные из Телеметрии
    pg_biz_hook = PostgresHook(postgres_conn_id='BUSINESS_DB_CONN')
    telemetry_df = pg_biz_hook.get_pandas_df("SELECT prosthesis_id, event_time, gesture_type, response_time_ms, battery_level FROM telemetry")
    logging.info(f"Extracted {len(telemetry_df)} telemetry records")
    
    if telemetry_df.empty or crm_df.empty:
        logging.warning("One of the source tables is empty. Skipping transformation.")
        return

    # 3. Трансформация (Агрегация за день)
    merged_df = telemetry_df.merge(crm_df, on='prosthesis_id')
    merged_df['report_date'] = pd.to_datetime(merged_df['event_time']).dt.date
    
    report_df = merged_df.groupby(['user_id', 'prosthesis_id', 'report_date']).agg(
        total_gestures=('gesture_type', 'count'),
        avg_response_time_ms=('response_time_ms', 'mean'),
        max_response_time_ms=('response_time_ms', 'max'),
        battery_usage_pct=('battery_level', lambda x: x.max() - x.min()),
        error_count=('response_time_ms', lambda x: (x > 200).sum())
    ).reset_index()
    
    logging.info(f"Prepared {len(report_df)} report rows")

    # 4. Загрузка в ClickHouse
    ch_host = "clickhouse"
    ch_port = 8123
    auth = ("default", "clickhouse")
    
    for _, row in report_df.iterrows():
        # Формируем запрос INSERT
        values = (
            f"'{row['user_id']}'",
            f"'{row['prosthesis_id']}'",
            f"'{row['report_date']}'",
            str(int(row['total_gestures'])),
            str(float(row['avg_response_time_ms'])),
            str(float(row['max_response_time_ms'])),
            str(float(row['battery_usage_pct'])),
            str(int(row['error_count']))
        )
        query = f"INSERT INTO user_report_showcase (user_id, prosthesis_id, report_date, total_gestures, avg_response_time_ms, max_response_time_ms, battery_usage_pct, error_count) VALUES ({', '.join(values)})"
        
        resp = requests.post(f"http://{ch_host}:{ch_port}/", data=query, auth=auth)
        if resp.status_code != 200:
            logging.error(f"Failed to load to ClickHouse: {resp.text}")
            raise Exception("ClickHouse load failed")

with DAG(
    'bionicpro_etl_process',
    default_args=default_args,
    description='ETL process for BionicPRO reporting',
    schedule_interval='@daily',
    catchup=False
) as dag:

    etl_task = PythonOperator(
        task_id='extract_transform_load',
        python_callable=extract_transform_load,
    )

