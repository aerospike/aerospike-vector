import pytest

from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys

def test_search(browser, app_url):
    browser.get(app_url + "/search")
    search_input = browser.find_element(By.ID, 'textInput')
    search_input.send_keys('dog')
    search_input.send_keys(Keys.RETURN)

    results_div = browser.find_element(By.ID, 'results')
    assert results_div.is_displayed(), "Results div is not displayed"

    # Find all elements within the results gallery
    gallery_items = results_div.find_elements(By.CSS_SELECTOR, ".gallery .responsive .quote")

    # Assert there are exactly 5 elements
    # By default the app returns 5 quotes
    assert len(gallery_items) == 5, f"Expected 5 elements in the gallery, but found {len(gallery_items)}."