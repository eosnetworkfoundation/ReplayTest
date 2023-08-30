"""
Module provides testing
Loading and dumping json config file
Marshling replay records.
Building config for replay node from json meta-data
Validation that file exists on os
Copy to preserve previous datastructure
"""
import pytest
import json
from pathlib import Path
import copy
from replay_configuration import ReplayConfigManager
from replay_configuration import BlockConfigManager

#### Replay Manager ####
def test_initialize_replay_manager():
    manager = ReplayConfigManager('../../meta-data/test-simple-jobs.json')
    assert manager is not None

def test_get_by_pk():
    manager = ReplayConfigManager('../../meta-data/test-simple-jobs.json')
    pk = 1
    block = manager.get(pk)
    assert block is not None
    assert block.replay_slice_id == pk

#### Block Manger ####
def test_initialize_block_manager_ok_with_s3():
    with open('../../meta-data/test-001-jobs.json', 'r') as f:
        records = json.load(f)
    primary_key = 1
    block = BlockConfigManager(records[0],primary_key)
    assert block is not None
    assert block._is_supported_storage_type() is True
    deb_url = block.get_leap_deb_url()
    assert deb_url.startswith("https://github.com/AntelopeIO/leap/releases/download/v")
    assert deb_url.endswith("ubuntu22.04_amd64.deb")
    assert block.validate_integrity_hash("ABCD1234EFGH5678IJKL9012MNOP3456") is True

def test_initialize_block_manager_ok_with_fs():
    with open('../../meta-data/test-001-jobs.json', 'r') as f:
        records = json.load(f)
    primary_key = 2
    block = BlockConfigManager(records[1],primary_key)
    assert block is not None
    assert block._is_supported_storage_type() is True
    assert block.get_snapshot_path() == records[1]["snapshot_path"]
    assert block.validate_integrity_hash("Z") is False

def test_initialize_block_manager_bad_record():
    with open('../../meta-data/test-001-jobs.json', 'r') as f:
        records = json.load(f)
    primary_key = 3
    with pytest.raises(KeyError):
        block = BlockConfigManager(records[2], primary_key)

def test_modify_block_config():
    manager = ReplayConfigManager('../../meta-data/test-simple-jobs.json')
    assert manager is not None
    primary_key = 1
    # preserve a copy
    orig_block = copy.deepcopy(manager.get(primary_key))
    # make a new config block objection
    new_block = copy.deepcopy(orig_block)
    new_block.start_block_id += 1000
    new_block.end_block_id += 1000
    # update the config
    is_success = manager.set(new_block)
    assert is_success is True
    # get back the block we modified
    updated_block = manager.get(primary_key)
    # validate start end block have changed and expected hash the same
    assert updated_block.start_block_id == orig_block.start_block_id + 1000
    assert updated_block.end_block_id == orig_block.end_block_id + 1000
    assert updated_block.expected_integrity_hash == orig_block.expected_integrity_hash

def test_dump_json_config():
    # our test files
    test_config_file = '../../meta-data/test-modify-jobs.json'
    test_orig_file = '../../meta-data/test-001-jobs.json'

    # test config is generated by a setup script and is not present in git
    # make sure it exists
    # skip test and print warning
    if Path(test_config_file).exists() and Path(test_config_file).is_file():

        manager = ReplayConfigManager(test_config_file)
        assert manager is not None
        # need the second record
        ok_config = manager.get(2)
        # the third record is broken lets fix it
        broken_config = manager.get(3)
        broken_config.start_block_id = ok_config.end_block_id + 501
        broken_config.end_block_id = broken_config.start_block_id + 99
        broken_config.snapshot_path = ok_config.snapshot_path
        broken_config.storage_type = ok_config.storage_type
        broken_config.expected_integrity_hash = ok_config.expected_integrity_hash
        broken_config.leap_version = ok_config.leap_version
        is_success = manager.set(broken_config)
        assert is_success is True
        # write out the updated json
        manager.persist()
        # asset files are different
        with open(test_config_file, 'r', encoding='utf-8') as f1, open(test_orig_file, 'r', encoding='utf-8') as f2:
            modified_config = f1.read()
            orig_config = f2.read()

        assert orig_config != modified_config
    else:
        print(f"WARNING: !!! {test_config_file} not present skipping test_dump_json_config !!!")