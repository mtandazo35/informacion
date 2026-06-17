<?php
$c = new mysqli('205.235.2.129', 'nqAvxta8EuxcdtTWN2xSywxdcjUDXGac', '', 'xui', 3306);
if ($c->connect_error) {
    echo 'CONNECT ERROR: ' . $c->connect_error . "\n";
} else {
    echo "Connected OK\n";
    $r = $c->query('SELECT COUNT(*) as n FROM streams');
    $row = $r->fetch_assoc();
    echo 'streams: ' . $row['n'] . "\n";
    $r2 = $c->query('SELECT COUNT(*) as n FROM streams_categories');
    $row2 = $r2->fetch_assoc();
    echo 'categories: ' . $row2['n'] . "\n";
}
