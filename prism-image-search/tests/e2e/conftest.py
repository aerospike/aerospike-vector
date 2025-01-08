import subprocess
import time

import pytest
from selenium import webdriver
from selenium.webdriver.chrome.options import Options

##########################################
###### GLOBALS
##########################################

DEFAULT_APP_ADDRESS = "127.0.0.1:8080"

##########################################
###### SUITE FLAGS
##########################################

def pytest_addoption(parser):
    parser.addoption("--app-address", action="store", default=DEFAULT_APP_ADDRESS, help="app address, ip:port")


@pytest.fixture(scope='session', autouse=True)
def app(request):
    return request.config.getoption("--app-address")


##########################################
###### FIXTURES
##########################################

@pytest.fixture(scope='function')
def browser():

    # Configure Chrome options
    # We do this mostly so that we can run headless in github actions
    chrome_options = Options()
    chrome_options.add_argument("--headless")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--window-size=1920,1080")

    driver = webdriver.Chrome(options=chrome_options)
    # Wait up to 30 seconds for elements to appear
    driver.implicitly_wait(30)
    yield driver
    driver.quit()


@pytest.fixture(scope='session')
def app_url(app):
    app_url = f"http://{app}"
    yield app_url
