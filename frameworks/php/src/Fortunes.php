<?php

// Standard mode wants a real template engine here, with the template as its own
// artifact rather than a string built in the handler. Twig is on the profile's
// list of accepted engines and escapes {{ }} by default, which is the check the
// profile calls load-bearing: row 11 of the seed carries a <script> tag.
//
// Loaded from the distribution's php-twig package - /usr/share/php is already on
// PHP's include_path - so the entry gains a template engine without gaining a
// composer install.
require_once '/usr/share/php/Twig/autoload.php';

class Fortunes
{
    private const RUNTIME = 'Additional fortune added at request time.';

    public static function render(): void
    {
        $pg = pg_pconnect('host=localhost port=5432 dbname=benchmark user=bench password=bench');
        $result = pg_query($pg, 'SELECT id, message FROM fortune');

        $fortunes = [];
        while ($row = pg_fetch_assoc($result)) {
            $fortunes[] = ['id' => (int) $row['id'], 'message' => $row['message']];
        }
        $fortunes[] = ['id' => 0, 'message' => self::RUNTIME];

        // Ordinal, not locale aware: the seed carries em-dashes and collation
        // rules would order them in a way the profile does not ask for.
        usort($fortunes, static fn($a, $b) => strcmp($a['message'], $b['message']));

        // The environment is built per request rather than cached to disk: the
        // profile forbids pre-rendered bodies, and compiling this one small
        // template is the render cost it means to measure.
        $twig = new \Twig\Environment(new \Twig\Loader\FilesystemLoader(__DIR__ . '/../views'));

        header('Content-Type: text/html; charset=utf-8');
        echo $twig->render('fortunes.twig', ['fortunes' => $fortunes]);
    }
}
