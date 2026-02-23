use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Linux::Event::Stream',
  AUTHOR       => 'Joshua S. Day <hax@cpan.org>',
  VERSION_FROM => 'lib/Linux/Event/Stream.pm',
  ABSTRACT_FROM=> 'lib/Linux/Event/Stream.pm',
  LICENSE      => 'perl',
  MIN_PERL_VERSION => '5.036000',
  PREREQ_PM => {
    'Linux::Event' => 0,
  },
  TEST_REQUIRES => {
    'Test2::V0' => 0,
    'Socket'   => 0,
  },
  META_MERGE => {
    resources => {
      repository => {
        type => 'git',
        url  => 'https://github.com/haxmeister/Linux-Event-Stream.git',
        web  => 'https://github.com/haxmeister/Linux-Event-Stream',
      },
      bugtracker => {
        web => 'https://github.com/haxmeister/Linux-Event-Stream/issues',
      },
    },
  },
);
