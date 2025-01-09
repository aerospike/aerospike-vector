import pytest

import requests

def test_search(app_url):

    response = requests.post(app_url + "/rest/v1/search", data={"text": "aerospike"})
    assert response.status_code == 200, f"Expected status code 200, but got {response.status_code}"

    # by default there is 1 photo in the data dir so expect 1
    results = response.json()["results"]
    assert len(results) == 1, f"Expected 1 results, but got {len(results)}"