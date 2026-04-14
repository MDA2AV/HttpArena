<?php

$dataset = json_decode(file_get_contents('/data/dataset.json'), true);

file_put_contents(__DIR__ . '/data.php', var_export($dataset, true).";", FILE_APPEND);

