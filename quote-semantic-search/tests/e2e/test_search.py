import pytest

import requests

def test_search(app_url):

    response = requests.post(app_url + "/rest/v1/search", data={"text": "dog"})
    assert response.status_code == 200, f"Expected status code 200, but got {response.status_code}"

    results = response.json()["results"]
    assert len(results) == 5, f"Expected 5 results, but got {len(results)}"