from pathlib import Path

from leadgen.core.models import ExternalResult, Lead, LeadKind, utcnow
from leadgen.storage.export import export
from leadgen.storage.state_crypto import decrypt_file, encrypt_file
from leadgen.storage.sqlite_store import Store


def mk(src="a", eid="1", title="Нужен сайт", desc="описание задачи"):
    return Lead(kind=LeadKind.ORDER, source=src, external_id=eid, title=title, description=desc)


def test_dedup_by_id_and_by_content(store):
    assert store.insert_lead(mk())
    assert not store.insert_lead(mk())                       # тот же ID
    assert not store.insert_lead(mk(src="b", eid="9"))       # тот же текст в другом источнике
    assert store.insert_lead(mk(src="b", eid="9", title="Другая заявка"))
    assert store.count_leads() == 2


def test_org_dedup_by_domain_or_phone(store):
    a = Lead(kind=LeadKind.ORGANIZATION, source="osm", external_id="n/1", title="A", website="https://www.a.ru/x")
    b = Lead(kind=LeadKind.ORGANIZATION, source="other", external_id="9", title="A (копия)", website="http://a.ru")
    assert store.insert_lead(a) and not store.insert_lead(b)


def test_json_roundtrip_and_external_results_kept_separately(store):
    l = mk()
    store.insert_lead(l)
    store.add_external_result(l.lead_id, ExternalResult(service="w", processed_at=utcnow(), ok=True, score=50))
    again = store.get_lead(l.lead_id)
    assert again.title == l.title and again.external_results == []   # исходные данные не перезаписаны
    assert store.external_results(l.lead_id)[0].score == 50
    assert store.was_sent_to(l.lead_id, "w")


def test_source_state_and_failures(store):
    assert store.mark_source_failure("s", "boom") == 1
    assert store.mark_source_failure("s", "boom") == 2
    store.mark_source_success("s", {"x": 1})
    st = store.source_state("s")
    assert st["consecutive_failures"] == 0 and st["cursor"] == {"x": 1} and st["last_success_at"]


def test_state_encryption_roundtrip(tmp_path: Path):
    db = tmp_path / "s.db"
    s = Store(db)
    s.insert_lead(mk())
    s.close()
    enc = tmp_path / "s.enc"
    encrypt_file(db, enc, "secret-key")
    assert b"\xd0\x9d\xd1\x83\xd0\xb6\xd0\xb5\xd0\xbd" not in enc.read_bytes()  # «Нужен» не виден в открытом виде
    out = tmp_path / "restored.db"
    assert not decrypt_file(enc, out, "wrong-key")
    assert decrypt_file(enc, out, "secret-key")
    assert Store(out).count_leads() == 1


def test_export_json_and_csv(store, tmp_path):
    store.insert_lead(mk())
    assert export(store, tmp_path / "a.json", "json") == 1
    assert export(store, tmp_path / "a.csv", "csv") == 1
    assert "Нужен сайт" in (tmp_path / "a.csv").read_text(encoding="utf-8")


def test_restore_marker_blocks_duplicates(store):
    l = mk()
    store.register_remote_key(l.lead_id, "a", "page-1")
    assert not store.insert_lead(l)
