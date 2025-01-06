import pytest
from selenium import webdriver

@pytest.fixture(scope='module')
def browser():
    driver = webdriver.Chrome()
    # Wait up to 5 seconds for elements to appear
    driver.implicitly_wait(5)
    yield driver
    driver.quit()