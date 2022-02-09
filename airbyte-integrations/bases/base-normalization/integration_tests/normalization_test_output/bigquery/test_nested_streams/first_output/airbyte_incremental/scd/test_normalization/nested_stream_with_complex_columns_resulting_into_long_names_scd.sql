

  create or replace table `dataline-integration-testing`.test_normalization.`nested_stream_with_complex_columns_resulting_into_long_names_scd`
  partition by range_bucket(
            _airbyte_active_row,
            generate_array(0, 1, 1)
        )
  cluster by _airbyte_unique_key_scd, _airbyte_emitted_at
  OPTIONS()
  as (
    
-- depends_on: ref('nested_stream_with_complex_columns_resulting_into_long_names_stg')
with

input_data as (
    select *
    from `dataline-integration-testing`._airbyte_test_normalization.`nested_stream_with_complex_columns_resulting_into_long_names_stg`
    -- nested_stream_with_complex_columns_resulting_into_long_names from `dataline-integration-testing`.test_normalization._airbyte_raw_nested_stream_with_complex_columns_resulting_into_long_names
),

scd_data as (
    -- SQL model to build a Type 2 Slowly Changing Dimension (SCD) table for each record identified by their primary key
    select
      to_hex(md5(cast(concat(coalesce(cast(id as 
    string
), '')) as 
    string
))) as _airbyte_unique_key,
      id,
      date,
      `partition`,
      date as _airbyte_start_at,
      lag(date) over (
        partition by id
        order by
            date is null asc,
            date desc,
            _airbyte_emitted_at desc
      ) as _airbyte_end_at,
      case when row_number() over (
        partition by id
        order by
            date is null asc,
            date desc,
            _airbyte_emitted_at desc
      ) = 1 then 1 else 0 end as _airbyte_active_row,
      _airbyte_ab_id,
      _airbyte_emitted_at,
      _airbyte_nested_stream_with_complex_columns_resulting_into_long_names_hashid
    from input_data
),
dedup_data as (
    select
        -- we need to ensure de-duplicated rows for merge/update queries
        -- additionally, we generate a unique key for the scd table
        row_number() over (
            partition by
                _airbyte_unique_key,
                _airbyte_start_at,
                _airbyte_emitted_at
            order by _airbyte_active_row desc, _airbyte_ab_id
        ) as _airbyte_row_num,
        to_hex(md5(cast(concat(coalesce(cast(_airbyte_unique_key as 
    string
), ''), '-', coalesce(cast(_airbyte_start_at as 
    string
), ''), '-', coalesce(cast(_airbyte_emitted_at as 
    string
), '')) as 
    string
))) as _airbyte_unique_key_scd,
        scd_data.*
    from scd_data
)
select
    _airbyte_unique_key,
    _airbyte_unique_key_scd,
    id,
    date,
    `partition`,
    _airbyte_start_at,
    _airbyte_end_at,
    _airbyte_active_row,
    _airbyte_ab_id,
    _airbyte_emitted_at,
    CURRENT_TIMESTAMP() as _airbyte_normalized_at,
    _airbyte_nested_stream_with_complex_columns_resulting_into_long_names_hashid
from dedup_data where _airbyte_row_num = 1
  );
  