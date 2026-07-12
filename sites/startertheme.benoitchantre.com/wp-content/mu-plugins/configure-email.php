<?php
/*
Plugin Name: Outgoing Email settings
Description: Forces wp_mail()'s From/Sender to match the SMTP account msmtp
             authenticates as (SMTP_FROM env var) — Infomaniak (and most
             relays) reject mail whose From doesn't match the authenticated
             account with "550 5.7.1 Sender mismatch". Actual SMTP transport
             is handled by msmtp via sendmail_path, not PHPMailer.
Version:     1.0.0
Author:      Benoît Chantre
Author URI:  https://benoitchantre.com
License:     GPL-2.0+
License URI: http://www.gnu.org/licenses/gpl-2.0.txt
*/

namespace Site\MU_Plugins\Outgoing_Email_Settings;

use function add_action;
use function add_filter;

/**
 * Filter $from_email
 *
 * @since 1.0.0
 *
 * @param string $from_email Email
 * @return string
 */
function filter_wp_from( string $from_email ) : string {
	$smtp_from = getenv( 'SMTP_FROM' );

	if ( $smtp_from && is_email( $smtp_from ) ) {
		return $smtp_from;
	}

	return $from_email;
}
add_filter( 'wp_mail_from', __NAMESPACE__ . '\filter_wp_from' );

/**
 * Configure PHPMailer's Sender (SMTP envelope from / return-path) to match
 * the authenticated SMTP account — this is what the relay actually checks,
 * separate from the From: header set via the filter above.
 *
 * @since 1.0.0
 *
 * @param \PHPMailer\PHPMailer\PHPMailer $phpmailer
 */
function action_configure_phpmailer( $phpmailer ) {
	$smtp_from = getenv( 'SMTP_FROM' );

	if ( $smtp_from && is_email( $smtp_from ) ) {
		$phpmailer->Sender = $smtp_from;
	}
}
add_action( 'phpmailer_init', __NAMESPACE__ . '\action_configure_phpmailer', 100 );

/**
 * Sends wp mail error to log
 */
function action_wp_mail_failed( $wp_error ) {
	return error_log( print_r( $wp_error, true ) );
}
add_action( 'wp_mail_failed', __NAMESPACE__ . '\action_wp_mail_failed' );
