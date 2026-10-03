"""Outgoing email over SMTP (e.g. Postmark). Unconfigured = sign-in disabled.

MAIL_LOG=true prints mails instead (local development only)."""
import logging
import os
import smtplib
from email.message import EmailMessage

log = logging.getLogger("score67.mail")


def enabled():
    return bool(os.getenv("SMTP_HOST")) or os.getenv("MAIL_LOG", "false").lower() == "true"


def send(to, subject, body):
    message = EmailMessage()
    message["From"] = os.getenv("MAIL_FROM", "Score67 <noreply@score67.de>")
    message["To"] = to
    message["Subject"] = subject
    message.set_content(body)
    host = os.getenv("SMTP_HOST")
    if not host:
        log.warning("MAIL_LOG to=%s subject=%s\n%s", to, subject, body)
        return
    with smtplib.SMTP(host, int(os.getenv("SMTP_PORT", "587")), timeout=20) as smtp:
        smtp.starttls()
        if os.getenv("SMTP_USER"):
            smtp.login(os.getenv("SMTP_USER"), os.getenv("SMTP_PASSWORD", ""))
        smtp.send_message(message)
