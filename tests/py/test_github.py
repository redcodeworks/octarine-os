"""The GitHub API as the scripts use it: the githubkit SDK directly (ci.github()) against the fake API. What the SDK does is what is tested: a 404 raises RequestFailed after ONE
request, a transport error is retried by the retry decision of ci.py, and a connection that stays broken raises the SDK's own RequestError."""
import pytest
from githubkit.exception import RequestError, RequestFailed

import ci
from conftest import fixture


def test_a_404_raises_the_sdk_error_after_one_request(github):
    gh = ci.github()
    with pytest.raises(RequestFailed) as e:
        gh.rest.repos.get_latest_release("o", "r")
    assert e.value.response.status_code == 404 and github.requests == [("GET", "/repos/o/r/releases/latest")]


def test_a_dropped_connection_is_retried(github):
    github.routes["/repos/o/r/releases/latest"] = fixture("release", tag_name="v1.2.3")
    github.drop = 2  # the first two connections are closed without an answer
    gh = ci.github()
    assert gh.rest.repos.get_latest_release("o", "r").parsed_data.tag_name == "v1.2.3"
    assert len(github.requests) == 3


def test_a_connection_that_stays_broken_raises_the_sdks_error_after_three_tries(github):
    github.drop = 99
    gh = ci.github()
    with pytest.raises(RequestError) as e:
        gh.rest.repos.get_latest_release("o", "r")
    assert not isinstance(e.value, RequestFailed) and len(github.requests) == 3


def test_the_token_server_and_typed_models(github):
    github.routes["/repos/o/r/releases/latest"] = fixture("release", tag_name="v9")
    gh = ci.github()
    release = gh.rest.repos.get_latest_release("o", "r").parsed_data
    assert (release.tag_name, type(release).__name__) == ("v9", "Release")


def test_paginate_is_a_lazy_iterator(github):
    github.routes["/repos/o/r/tags"] = [{**fixture("tag"), "name": "v1"}, {**fixture("tag"), "name": "v2"}]
    gh = ci.github()
    assert next(t.name for t in gh.rest.paginate(gh.rest.repos.list_tags, owner="o", repo="r") if t.name == "v2") == "v2"


def test_versions_order_numerically_not_alphabetically():
    assert ci.version("v1.10.0") > ci.version("v1.9.0") and ci.version("1.0.3") < ci.version("v1.1.0")
