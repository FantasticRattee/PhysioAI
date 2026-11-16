'use client';

import Icon from './Icon.jsx';
import Logo from './Logo.jsx';
import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';

export default function Topbar({ activeSection = 'plan', lang, therapist, onToggleLanguage, onSignOut }) {
  const th = lang === 'th';
  const [accountMenuOpen, setAccountMenuOpen] = useState(false);
  const accountMenuRef = useRef(null);

  useEffect(() => {
    if (!accountMenuOpen) return undefined;

    const closeOnOutsidePress = (event) => {
      if (!accountMenuRef.current?.contains(event.target)) setAccountMenuOpen(false);
    };
    const closeOnEscape = (event) => {
      if (event.key === 'Escape') setAccountMenuOpen(false);
    };

    document.addEventListener('pointerdown', closeOnOutsidePress);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePress);
      document.removeEventListener('keydown', closeOnEscape);
    };
  }, [accountMenuOpen]);

  return (
    <header className="topbar">
      <Logo />
      <nav className="product-nav" aria-label={th ? 'เมนูหลัก' : 'Primary navigation'}>
        <Link className={activeSection === 'plan' ? 'active' : ''} href="/therapist/plan">
          <Icon name="plan" size={19} />
          <span>{th ? 'แผนการรักษา' : 'Treatment plan'}</span>
        </Link>
        <Link className={activeSection === 'messages' ? 'active' : ''} href="/therapist/messages">
          <Icon name="message" size={19} />
          <span>{th ? 'ข้อความ' : 'Messages'}</span>
        </Link>
        <Link className={activeSection === 'history' ? 'active' : ''} href="/therapist/history">
          <Icon name="history" size={19} />
          <span>{th ? 'ประวัติ' : 'History'}</span>
        </Link>
      </nav>
      <div className="topbar-actions">
        {onToggleLanguage ? (
          <button className="icon-button" type="button" onClick={onToggleLanguage} aria-label={th ? 'Switch to English' : 'เปลี่ยนเป็นภาษาไทย'}>
            <Icon name="language" size={17} />
            <span>{th ? 'TH' : 'EN'}</span>
          </button>
        ) : null}
        <div className="account-menu" ref={accountMenuRef}>
          <button
            aria-controls="therapist-account-menu"
            aria-expanded={accountMenuOpen}
            aria-haspopup="menu"
            aria-label={th ? 'เปิดเมนูโปรไฟล์' : 'Open profile menu'}
            className="profile-button"
            onClick={() => setAccountMenuOpen((current) => !current)}
            type="button"
          >
            <Icon name="user" size={22} strokeWidth={2} />
          </button>
          {accountMenuOpen ? (
            <div className="account-popover" id="therapist-account-menu" role="menu">
              <div className="account-popover-identity">
                <span className="account-popover-avatar"><Icon name="user" size={21} strokeWidth={2} /></span>
                <span className="account-popover-copy" title={therapist?.name}>
                  <strong>{therapist?.name}</strong>
                  <small>{therapist?.role}</small>
                </span>
              </div>
              <div className="account-popover-divider" />
              <form action={onSignOut} className="signout-form">
                <button className="account-logout-button" role="menuitem" type="submit">
                  <Icon name="logout" size={18} />
                  <span>{th ? 'ออกจากระบบ' : 'Log out'}</span>
                </button>
              </form>
            </div>
          ) : null}
        </div>
      </div>
    </header>
  );
}
