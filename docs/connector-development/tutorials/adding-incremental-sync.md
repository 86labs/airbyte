# Adding Incremental Sync to a Source

## Overview

This tutorial will assume that you already have a working source. If you do not, feel free to refer to the [Building a Toy Connector](building-a-python-source.md) tutorial. This tutorial will build directly off the example from that article. We will also assume that you have a basic understanding of how Airbyte's Incremental-Append replication strategy works. We have a brief explanation of it [here](../../understanding-airbyte/connections/incremental-append.md).

## Update Catalog in `discover`

First we need to identify a given stream in the Source as supporting incremental. This information is declared in the catalog that the `discover` method returns. You will notice in the stream object contains a field called `supported_sync_modes`. If we are adding incremental to an existing stream, we just need to add `"incremental"` to that array. This tells Airbyte that this stream can either be synced in an incremental fashion. In practice, this will mean that in the UI, a user will have the ability to configure this type of sync.

In the example we used in the Toy Connector tutorial, the `discover` method would not look like this. Note: that "incremental" has been added to the `supported_sync_modes` array. We also set `source_defined_cursor` to `True` to declare that the Source knows what field to use for the cursor, in this case the date field, and does not require user input. Nothing else has changed.

```python
def discover():
    catalog = {
        "streams": [{
            "name": "stock_prices",
            "supported_sync_modes": ["full_refresh", "incremental"],
            "source_defined_cursor": True,
            "json_schema": {
                "properties": {
                    "date": {
                        "type": "string"
                    },
                    "price": {
                        "type": "number"
                    },
                    "stock_ticker": {
                        "type": "string"
                    }
                }
            }
        }]
    }
    airbyte_message = {"type": "CATALOG", "catalog": catalog}
    print(json.dumps(airbyte_message))
```

## Update `read`

Next we will adapt the `read` method that we wrote previously. We need to change three things.

First, we need to pass it information about what data was replicated in the previous sync. In Airbyte this is called a `state` object. The structure of the state object is determined by the Source. This means that each Source can construct a state object that makes sense to it and does not need to worry about adhering to any other convention. That being said, a pretty typical structure for a state object is a map of stream name to the last value in the cursor field for that stream.

In this case we might choose something like this:

```javascript
{
  "stock_prices": "2020-02-01"
}
```

The second change we need to make to the `read` method is to use the state object so that we only emit new records. 

Lastly, we need to emit an updated state object, so that the next time this Source runs we do not resend messages that we have already sent.

Here's what our updated `read` method would look like.

```python
def read(config, catalog, state):
    # Assert required configuration was provided
    if "api_key" not in config or "stock_ticker" not in config:
        log("Input config must contain the properties 'api_key' and 'stock_ticker'")
        sys.exit(1)

    # Find the stock_prices stream if it is present in the input catalog
    stock_prices_stream = None
    for configured_stream in catalog["streams"]:
        if configured_stream["stream"]["name"] == "stock_prices":
            stock_prices_stream = configured_stream

    if stock_prices_stream is None:
        log("No streams selected")
        return

    # By default we fetch stock prices for the 7 day period ending with today
    today = date.today()
    cursor_value = today.strftime("%Y-%m-%d")
    from_day = (today - timedelta(days=7)).strftime("%Y-%m-%d")

    # In case of incremental sync, state should contain the last date when we fetched stock prices
    if stock_prices_stream["sync_mode"] == "incremental":
        if state and state.get("stock_prices"):
            from_date = datetime.strptime(state.get("stock_prices"), "%Y-%m-%d")
            from_day = (from_date + timedelta(days=1)).strftime("%Y-%m-%d")

    # If the state indicates that we have already ran the sync up to cursor_value, we can skip the sync
    if cursor_value != from_day:
        # If we've made it this far, all the configuration is good and we can pull the market data
        response = _call_api(ticker=config["stock_ticker"], token = config["api_key"], from_day=from_day, to_day=cursor_value)
        if response.status_code != 200:
            # In a real scenario we'd handle this error better :)
            log("Failure occurred when calling Polygon.io API")
            sys.exit(1)
        else:
            # Stock prices are returned sorted by date in ascending order
            # We want to output them one by one as AirbyteMessages
            response_json = response.json()
            if response_json["resultsCount"] > 0:
                results = response_json["results"]
                for result in results:
                    data = {"date": datetime.fromtimestamp(result["t"]/1000, tz=timezone.utc).strftime("%Y-%m-%d"), "stock_ticker": config["stock_ticker"], "price": result["c"]}
                    record = {"stream": "stock_prices", "data": data, "emitted_at": int(datetime.now().timestamp()) * 1000}
                    output_message = {"type": "RECORD", "record": record}
                    print(json.dumps(output_message))

                    # We update the cursor as we print out the data, so that next time sync starts where we stopped printing out results
                    if stock_prices_stream["sync_mode"] == "incremental":
                        cursor_value = datetime.fromtimestamp(results[len(results)-1]["t"]/1000, tz=timezone.utc).strftime("%Y-%m-%d")

    # Emit new state message.
    if stock_prices_stream["sync_mode"] == "incremental":
        output_message = {"type": "STATE", "state": {"data": {"stock_prices": cursor_value}}}
        print(json.dumps(output_message))
```

We will also need to parse `state` argument in the `run` method. In order to do that, we will modify the code that 
calls `read` method from `run` method:
```python
    elif command == "read":
        config = read_json(get_input_file_path(parsed_args.config))
        configured_catalog = read_json(get_input_file_path(parsed_args.catalog))
        state = None
        if parsed_args.state:
            state = read_json(get_input_file_path(parsed_args.state))

        read(config, configured_catalog, state)
```
Finally, we need to pass more arguments to our `_call_api` method in order to fetch only new prices for incremental sync:
```python
def _call_api(ticker, token, from_day, to_day):
    return requests.get(f"https://api.polygon.io/v2/aggs/ticker/{ticker}/range/1/day/{from_day}/{to_day}?sort=asc&limit=120&apiKey={token}")
```

You will notice that in order to test these changes you need a `state` object. If you run an incremental sync
without passing a state object, the new code will output a state object that you can use with the next sync. If you run this:
```bash
python source.py read --config secrets/valid_config.json --catalog incremental_configured_catalog.json
```

The output will look like following:
```bash
{"type": "RECORD", "record": {"stream": "stock_prices", "data": {"date": "2022-03-07", "stock_ticker": "TSLA", "price": 804.58}, "emitted_at": 1647294277000}}
{"type": "RECORD", "record": {"stream": "stock_prices", "data": {"date": "2022-03-08", "stock_ticker": "TSLA", "price": 824.4}, "emitted_at": 1647294277000}}
{"type": "RECORD", "record": {"stream": "stock_prices", "data": {"date": "2022-03-09", "stock_ticker": "TSLA", "price": 858.97}, "emitted_at": 1647294277000}}
{"type": "RECORD", "record": {"stream": "stock_prices", "data": {"date": "2022-03-10", "stock_ticker": "TSLA", "price": 838.3}, "emitted_at": 1647294277000}}
{"type": "RECORD", "record": {"stream": "stock_prices", "data": {"date": "2022-03-11", "stock_ticker": "TSLA", "price": 795.35}, "emitted_at": 1647294277000}}
{"type": "STATE", "state": {"data": {"stock_prices": "2022-03-11"}}}
```

Notice that the last line of output is the state object. Copy the state object:
```json
{"stock_prices": "2022-03-11"}
```
and paste it into a new file (i.e. `state.json`). Now you can run an incremental sync:
```bash
python source.py read --config secrets/valid_config.json --catalog incremental_configured_catalog.json --state state.json 
```

That's all you need to do to add incremental functionality to the stock ticker Source.

You can deploy the new version of your connector simply by running:
```bash
./gradlew clean :airbyte-integrations:connectors:source-stock-ticker-api:build
```

Bonus points: go to Airbyte UI and reconfigure the connection to use incremental sync.

Incremental definitely requires more configurability than full refresh, so your implementation may deviate slightly depending on whether your cursor
field is source defined or user-defined. If you think you are running into one of those cases, check out 
our [incremental](../../understanding-airbyte/connections/incremental-append.md) documentation for more information on different types of
configuration.

