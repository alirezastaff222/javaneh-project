import type { Metadata } from "next";
import type { ReactNode } from "react";
import { Geist, Geist_Mono, Vazirmatn } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const vazirmatn = Vazirmatn({
  variable: "--font-vazirmatn",
  subsets: ["arabic"],
});

export const metadata: Metadata = {
  title: "Javaneh | Social Innovation Platform",
  description: "Turn social challenges into thoughtful, workable ideas for your community.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html
      lang="fa"
      dir="rtl"
      className={`${geistSans.variable} ${geistMono.variable} ${vazirmatn.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
