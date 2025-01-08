import subprocess
import time

import pytest
from selenium import webdriver

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
    driver = webdriver.Chrome()
    # Wait up to 30 seconds for elements to appear
    driver.implicitly_wait(30)
    yield driver
    driver.quit()


@pytest.fixture(scope='session')
def app_url(app):
    app_url = f"http://{app}"
    yield app_url
