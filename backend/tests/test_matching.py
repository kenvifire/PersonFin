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


def test_suggest_account_matches_when_only_account_label_given(db_session):
    """With `institution=None`, the comparison string must be just the
    label — not "None TFSA", whose literal "none" drags the similarity
    of "tfsa" vs. "rbc tfsa" from 0.67 down to 0.59, below threshold."""
    user = User(google_sub="g-4", email="d@example.com")
    db_session.add(user)
    db_session.commit()
    account = Account(user_id=user.id, name="TFSA", institution="RBC", account_type="tfsa")
    db_session.add(account)
    db_session.commit()

    matched = suggest_account(db_session, user.id, institution=None, account_label="TFSA")
    assert matched is not None
    assert matched.id == account.id


def test_suggest_account_matches_when_only_institution_given(db_session):
    user = User(google_sub="g-5", email="e@example.com")
    db_session.add(user)
    db_session.commit()
    account = Account(user_id=user.id, name="TFSA", institution="RBC", account_type="tfsa")
    db_session.add(account)
    db_session.commit()

    # "rbc tf" vs. "rbc tfsa" is 0.86; the buggy "rbc tf none" is 0.63.
    # Either clears the threshold, so this guards the institution-only
    # path against regression rather than reproducing the bug.
    matched = suggest_account(db_session, user.id, institution="RBC TF", account_label=None)
    assert matched is not None
    assert matched.id == account.id


def test_suggest_account_with_no_accounts_returns_none(db_session):
    user = User(google_sub="g-3", email="c@example.com")
    db_session.add(user)
    db_session.commit()
    assert suggest_account(db_session, user.id, institution="RBC", account_label="RRSP") is None
