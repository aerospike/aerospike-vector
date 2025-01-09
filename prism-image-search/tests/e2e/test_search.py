import pytest

from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys

def test_search(browser, app_url):
    browser.get(app_url + "/search")
    search_input = browser.find_element(By.ID, 'textInput')
    search_input.send_keys('aerospike')
    search_input.send_keys(Keys.RETURN)

    results_div = browser.find_element(By.ID, 'results')
    assert results_div.is_displayed(), "Results div is not displayed"

    # Find all elements within the search resultsgallery
    gallery_items = results_div.find_elements(By.CSS_SELECTOR, ".responsive .gallery .search-result")

    # Assert there are exactly 1 elements
    # This assumes that the app was started without adding any additional images to the data file
    # By default, there is 1 image in the data file
    assert len(gallery_items) == 1, f"Expected 1 elements in the gallery, but found {len(gallery_items)}."