import pytest
from selenium import webdriver

@pytest.fixture(scope='module')
def browser():
    driver = webdriver.Chrome()
    # Wait up to 30 seconds for elements to appear
    driver.implicitly_wait(30)
    yield driver
    driver.quit()