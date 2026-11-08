"""`suggest_account`: a plain string-similarity guess at which of the
user's existing `Account` rows a freshly extracted upload belongs to.
No LLM call — just `difflib.SequenceMatcher` over institution + label.
"""

from app.models import Account, User
from app.services.matching import suggest_account


def test_suggest_account_matches_similar_institution_name(db_session):
    user = User(google_sub="g-1", email="a@example.com")
    db_session.add(user)
    db_session.commit()
    account = Account(user_id=user.id, name="RRSP", institution="Royal Bank of Canada", account_type="rrsp")
    db_session.add(account)
    db_session.commit()

    matched = suggest_account(db_session, user.id, institution="RBC Royal Bank", account_label="RRSP")
    assert matched is not None
    assert matched.id == account.id


def test_suggest_account_returns_none_below_threshold(db_session):
    user = User(google_sub="g-2", email="b@example.com")
    db_session.add(user)
    db_session.commit()
    account = Account(user_id=user.id, name="Checking", institution="Totally Different Bank", account_type="cash")
    db_session.add(account)
    db_session.commit()

    assert suggest_account(db_session, user.id, institution="Unrelated Crypto Exchange", account_label="Wallet") is None


def test_suggest_account_with_no_accounts_returns_none(db_session):
    user = User(google_sub="g-3", email="c@example.com")
    db_session.add(user)
    db_session.commit()
    assert suggest_account(db_session, user.id, institution="RBC", account_label="RRSP") is None
